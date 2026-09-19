#!/usr/bin/env python3
"""Serve a private, localhost-only UI for correcting QAP.ia transcripts."""

from __future__ import annotations

import argparse
import json
import mimetypes
import os
import re
import secrets
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlparse

from audit_teacher_transcripts import tokens


SAMPLE_ID_PATTERN = re.compile(r"^[a-f0-9]{12}$")
CONSENT_STATUSES = {
    "pending_documentation",
    "approved_for_private_training",
    "excluded",
}
CHECKLIST_KEYS = (
    "audioReviewed",
    "completenessChecked",
    "numbersChecked",
    "namesAndAcronymsChecked",
    "uncertaintiesMarked",
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--queue", type=Path, required=True)
    parser.add_argument("--dataset-root", type=Path, required=True)
    parser.add_argument("--teacher-root", type=Path, required=True)
    parser.add_argument("--annotations-root", type=Path, required=True)
    parser.add_argument("--token-file", type=Path, required=True)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--allow-non-loopback", action="store_true")
    return parser.parse_args()


def safe_path(root: Path, relative: str) -> Path:
    root = root.resolve()
    candidate = (root / relative).resolve()
    try:
        candidate.relative_to(root)
    except ValueError as error:
        raise ValueError("Path escapes its private root") from error
    return candidate


def write_private_text(path: Path, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(value, encoding="utf-8")
    os.chmod(temporary, 0o600)
    temporary.replace(path)


def write_private_json(path: Path, value: dict[str, Any]) -> None:
    write_private_text(
        path,
        json.dumps(value, ensure_ascii=False, indent=2) + "\n",
    )


def load_or_create_token(token_file: Path) -> str:
    token_file = token_file.resolve()
    if token_file.is_file():
        token = token_file.read_text(encoding="utf-8").strip()
        if len(token) < 32:
            raise ValueError("Existing review token is too short")
        os.chmod(token_file, 0o600)
        return token
    token = secrets.token_urlsafe(32)
    write_private_text(token_file, token + "\n")
    return token


class AnnotationStore:
    def __init__(
        self,
        queue_path: Path,
        dataset_root: Path,
        teacher_root: Path,
        annotations_root: Path,
    ) -> None:
        self.queue_path = queue_path.resolve()
        self.dataset_root = dataset_root.resolve()
        self.teacher_root = teacher_root.resolve()
        self.annotations_root = annotations_root.resolve()
        self.annotations_root.mkdir(parents=True, exist_ok=True)
        os.chmod(self.annotations_root, 0o700)
        self.queue = json.loads(self.queue_path.read_text(encoding="utf-8"))
        self.entries = {
            entry["sampleId"]: entry for entry in self.queue.get("entries", [])
        }
        if len(self.entries) != len(self.queue.get("entries", [])):
            raise ValueError("Duplicate sample ID in annotation queue")

    def _entry(self, sample_id: str) -> dict[str, Any]:
        if not SAMPLE_ID_PATTERN.fullmatch(sample_id) or sample_id not in self.entries:
            raise KeyError("Unknown sample")
        return self.entries[sample_id]

    def _sample_root(self, sample_id: str) -> Path:
        self._entry(sample_id)
        return safe_path(self.annotations_root, sample_id)

    def _annotation_path(self, sample_id: str) -> Path:
        return self._sample_root(sample_id) / "annotation.json"

    def _corrected_path(self, sample_id: str) -> Path:
        return self._sample_root(sample_id) / "corrected.transcript.txt"

    def read_annotation(self, sample_id: str) -> dict[str, Any] | None:
        path = self._annotation_path(sample_id)
        if not path.is_file():
            return None
        return json.loads(path.read_text(encoding="utf-8"))

    def queue_payload(self) -> dict[str, Any]:
        items = []
        for entry in sorted(self.entries.values(), key=lambda item: item["rank"]):
            annotation = self.read_annotation(entry["sampleId"])
            items.append(
                {
                    "sampleId": entry["sampleId"],
                    "rank": entry["rank"],
                    "durationBucket": entry["durationBucket"],
                    "signals": entry["signals"],
                    "consentStatus": (
                        annotation["consentStatus"]
                        if annotation
                        else entry["consentStatus"]
                    ),
                    "asrReviewStatus": (
                        annotation["asrReviewStatus"]
                        if annotation
                        else entry["asrReviewStatus"]
                    ),
                }
            )
        approved = sum(item["asrReviewStatus"] == "approved" for item in items)
        excluded = sum(item["asrReviewStatus"] == "excluded" for item in items)
        training_ready = sum(
            item["asrReviewStatus"] == "approved"
            and item["consentStatus"] == "approved_for_private_training"
            for item in items
        )
        return {
            "classification": "private-sensitive-restricted",
            "total": len(items),
            "approved": approved,
            "excluded": excluded,
            "trainingReady": training_ready,
            "items": items,
        }

    def meeting_payload(self, sample_id: str) -> dict[str, Any]:
        entry = self._entry(sample_id)
        teacher_path = self.teacher_root / f"{sample_id}.json"
        teacher = json.loads(teacher_path.read_text(encoding="utf-8"))
        current_path = safe_path(self.dataset_root, entry["currentTranscriptFile"])
        annotation = self.read_annotation(sample_id)
        corrected_path = self._corrected_path(sample_id)
        corrected = (
            corrected_path.read_text(encoding="utf-8")
            if corrected_path.is_file()
            else teacher.get("draft_transcript", "")
        )
        checklist = {
            key: bool((annotation or {}).get("reviewChecklist", {}).get(key, False))
            for key in CHECKLIST_KEYS
        }
        return {
            "sampleId": sample_id,
            "rank": entry["rank"],
            "signals": entry["signals"],
            "currentTranscript": current_path.read_text(encoding="utf-8"),
            "teacherTranscript": teacher.get("draft_transcript", ""),
            "correctedTranscript": corrected,
            "audio": [
                {"index": index, "label": f"Trecho {index + 1}"}
                for index, _ in enumerate(entry["audioFiles"])
            ],
            "consentStatus": (
                annotation["consentStatus"]
                if annotation
                else entry["consentStatus"]
            ),
            "asrReviewStatus": (
                annotation["asrReviewStatus"]
                if annotation
                else entry["asrReviewStatus"]
            ),
            "reviewer": (annotation or {}).get("reviewer") or "",
            "reviewNotes": "\n".join((annotation or {}).get("reviewNotes", [])),
            "reviewChecklist": checklist,
        }

    def audio_path(self, sample_id: str, index: int) -> Path:
        entry = self._entry(sample_id)
        audio_files = entry["audioFiles"]
        if index < 0 or index >= len(audio_files):
            raise KeyError("Unknown audio source")
        return safe_path(self.dataset_root, audio_files[index])

    def save_review(self, sample_id: str, payload: dict[str, Any]) -> dict[str, Any]:
        entry = self._entry(sample_id)
        decision = str(payload.get("decision", "save"))
        if decision not in {"save", "approve", "exclude"}:
            raise ValueError("Invalid review decision")
        consent_status = str(payload.get("consentStatus", entry["consentStatus"]))
        if consent_status not in CONSENT_STATUSES:
            raise ValueError("Invalid consent status")
        reviewer = str(payload.get("reviewer", "")).strip()
        if len(reviewer) > 120:
            raise ValueError("Reviewer identifier is too long")
        corrected = str(payload.get("correctedTranscript", "")).replace("\r\n", "\n").strip()
        notes_text = str(payload.get("reviewNotes", "")).replace("\r\n", "\n")
        notes = [line.strip() for line in notes_text.splitlines() if line.strip()]
        checklist_payload = payload.get("reviewChecklist", {})
        checklist = {
            key: bool(checklist_payload.get(key, False)) for key in CHECKLIST_KEYS
        }

        if decision == "approve":
            if not reviewer:
                raise ValueError("Reviewer is required for approval")
            if len(tokens(corrected)) < 30:
                raise ValueError("Corrected transcript is too short for approval")
            if not all(checklist.values()):
                raise ValueError("All ASR review checks are required for approval")
            asr_status = "approved"
        elif decision == "exclude":
            if not reviewer or not notes:
                raise ValueError("Reviewer and exclusion reason are required")
            asr_status = "excluded"
        else:
            asr_status = "pending_human_correction"

        sample_root = self._sample_root(sample_id)
        corrected_path = self._corrected_path(sample_id)
        corrected_reference: str | None = None
        if corrected:
            write_private_text(corrected_path, corrected + "\n")
            corrected_reference = str(
                corrected_path.relative_to(self.annotations_root.parent)
            )

        reviewed_at = datetime.now(timezone.utc).isoformat()
        annotation = {
            "schemaVersion": 1,
            "sampleId": sample_id,
            "consentStatus": consent_status,
            "asrReviewStatus": asr_status,
            "minutesReviewStatus": "excluded" if asr_status == "excluded" else "pending",
            "teacherTranscriptFile": entry["teacherTranscriptFile"],
            "correctedTranscriptFile": corrected_reference,
            "evidenceLedgerFile": None,
            "referenceMinutesFile": None,
            "split": "excluded" if asr_status == "excluded" else entry["split"],
            "reviewNotes": notes,
            "reviewer": reviewer or None,
            "reviewedAt": reviewed_at,
            "reviewChecklist": checklist,
        }
        write_private_json(sample_root / "annotation.json", annotation)
        event = {
            "sampleId": sample_id,
            "decision": decision,
            "asrReviewStatus": asr_status,
            "consentStatus": consent_status,
            "reviewer": reviewer or None,
            "reviewedAt": reviewed_at,
        }
        event_path = self.annotations_root / "review-events.jsonl"
        descriptor = os.open(
            event_path,
            os.O_APPEND | os.O_CREAT | os.O_WRONLY,
            0o600,
        )
        try:
            os.write(
                descriptor,
                (json.dumps(event, ensure_ascii=False) + "\n").encode("utf-8"),
            )
        finally:
            os.close(descriptor)
        os.chmod(event_path, 0o600)
        return annotation


HTML = r"""<!doctype html>
<html lang="pt-BR">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>QAP.ia · Revisão privada de transcrição</title>
  <style>
    :root { color-scheme: light dark; --bg:#0d1117; --panel:#161b22; --soft:#21262d; --line:#30363d; --text:#f0f6fc; --muted:#8b949e; --accent:#7c9cff; --good:#3fb950; --warn:#d29922; --bad:#f85149; }
    * { box-sizing:border-box; }
    body { margin:0; min-height:100vh; background:var(--bg); color:var(--text); font:14px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; }
    header { height:64px; display:flex; align-items:center; gap:18px; padding:0 22px; border-bottom:1px solid var(--line); background:rgba(13,17,23,.94); position:sticky; top:0; z-index:3; }
    h1 { font-size:17px; margin:0; }
    .privacy { color:var(--muted); flex:1; }
    .progress { font-variant-numeric:tabular-nums; }
    .layout { display:grid; grid-template-columns:300px minmax(0,1fr); min-height:calc(100vh - 64px); }
    aside { border-right:1px solid var(--line); background:var(--panel); overflow:auto; max-height:calc(100vh - 64px); }
    .queue-head { padding:16px; border-bottom:1px solid var(--line); position:sticky; top:0; background:var(--panel); z-index:2; }
    .queue { list-style:none; padding:8px; margin:0; }
    .queue button { width:100%; text-align:left; border:1px solid transparent; background:transparent; color:inherit; padding:11px; border-radius:9px; cursor:pointer; margin-bottom:4px; }
    .queue button:hover,.queue button.active { background:var(--soft); border-color:var(--line); }
    .row { display:flex; justify-content:space-between; gap:8px; align-items:center; }
    .muted { color:var(--muted); font-size:12px; }
    .badge { border-radius:999px; padding:2px 7px; font-size:11px; font-weight:650; }
    .urgent { background:rgba(248,81,73,.18); color:#ff7b72; }
    .high { background:rgba(210,153,34,.18); color:#e3b341; }
    .medium { background:rgba(124,156,255,.18); color:#a5b8ff; }
    .normal { background:rgba(63,185,80,.16); color:#56d364; }
    main { padding:22px; overflow:auto; max-height:calc(100vh - 64px); }
    .empty { max-width:680px; margin:12vh auto; text-align:center; color:var(--muted); }
    .toolbar,.card { background:var(--panel); border:1px solid var(--line); border-radius:12px; padding:16px; margin-bottom:16px; }
    .toolbar { display:flex; flex-wrap:wrap; gap:12px; align-items:center; }
    .toolbar h2 { margin:0 auto 0 0; font-size:18px; }
    .signals { display:flex; flex-wrap:wrap; gap:8px; }
    .signal { background:var(--soft); border-radius:7px; padding:6px 9px; font-variant-numeric:tabular-nums; }
    audio { width:100%; margin-top:8px; }
    .audio-row + .audio-row { margin-top:12px; }
    .editors { display:grid; grid-template-columns:1fr 1fr; gap:16px; }
    label { display:block; font-weight:650; margin-bottom:7px; }
    textarea,input,select { width:100%; background:var(--bg); color:var(--text); border:1px solid var(--line); border-radius:8px; padding:10px; font:inherit; }
    textarea { min-height:420px; resize:vertical; }
    textarea[readonly] { color:#c9d1d9; background:#0b0f14; }
    .review-grid { display:grid; grid-template-columns:minmax(220px,1fr) minmax(260px,2fr); gap:18px; }
    .checks { display:grid; gap:8px; }
    .checks label { display:flex; gap:9px; font-weight:400; align-items:flex-start; margin:0; }
    .checks input { width:auto; margin-top:3px; }
    .actions { display:flex; gap:10px; justify-content:flex-end; margin-top:16px; }
    button.action { border:1px solid var(--line); border-radius:8px; padding:9px 14px; color:var(--text); background:var(--soft); cursor:pointer; font-weight:650; }
    button.primary { background:#3859c7; border-color:#5675e6; }
    button.danger { background:#6e2525; border-color:#9f3a38; }
    .status { min-height:22px; margin-top:10px; color:var(--muted); text-align:right; }
    @media (max-width:900px) { .layout{grid-template-columns:1fr}.layout aside{max-height:260px;border-right:0;border-bottom:1px solid var(--line)} main{max-height:none}.editors,.review-grid{grid-template-columns:1fr} }
  </style>
</head>
<body>
  <header>
    <h1>QAP.ia · Revisão privada</h1>
    <div class="privacy">Áudio e texto permanecem no servidor IA. Nenhum item é liberado para treino automaticamente.</div>
    <div class="progress" id="progress">Carregando…</div>
  </header>
  <div class="layout">
    <aside>
      <div class="queue-head"><strong>Fila de maior risco primeiro</strong><div class="muted">Prioridade orienta revisão; não mede acurácia.</div></div>
      <ol class="queue" id="queue"></ol>
    </aside>
    <main id="main"><div class="empty"><h2>Selecione uma reunião</h2><p>Ouça o áudio completo e corrija o rascunho antes de aprovar.</p></div></main>
  </div>
  <script>
    if (window.location.search) history.replaceState({}, document.title, window.location.pathname);
    const state = { queue: null, selected: null };
    const bands = { urgent:"Urgente", high:"Alta", medium:"Média", normal:"Normal" };
    const checklistLabels = {
      audioReviewed:"Áudio integralmente revisado",
      completenessChecked:"Omissões e repetições verificadas",
      numbersChecked:"Números, datas e prazos conferidos",
      namesAndAcronymsChecked:"Nomes, termos e siglas conferidos",
      uncertaintiesMarked:"Incertezas marcadas sem adivinhação"
    };
    function esc(value){ return String(value).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])); }
    async function api(path, options={}){
      const headers = Object.assign({'Accept':'application/json'}, options.headers || {});
      if(options.body){ headers['Content-Type']='application/json'; headers['X-Qapia-Review']='1'; }
      const response = await fetch(path, Object.assign({}, options, {headers, credentials:'same-origin'}));
      const body = await response.json().catch(() => ({}));
      if(!response.ok) throw new Error(body.error || `Falha HTTP ${response.status}`);
      return body;
    }
    async function loadQueue(){
      state.queue = await api('/api/queue');
      document.getElementById('progress').textContent = `${state.queue.approved} aprovadas · ${state.queue.trainingReady} aptas para treino · ${state.queue.total} total`;
      const list = document.getElementById('queue'); list.textContent='';
      state.queue.items.forEach(item => {
        const li=document.createElement('li'); const button=document.createElement('button');
        button.className = item.sampleId===state.selected ? 'active' : '';
        const status = item.asrReviewStatus==='approved' ? '✓ aprovada' : item.asrReviewStatus==='excluded' ? 'excluída' : 'pendente';
        button.innerHTML = `<div class="row"><strong>#${item.rank}</strong><span class="badge ${esc(item.signals.priorityBand)}">${bands[item.signals.priorityBand]}</span></div><div class="row muted"><span>${Math.round(item.signals.audioSeconds/60)} min</span><span>${status}</span></div>`;
        button.onclick=()=>openMeeting(item.sampleId); li.appendChild(button); list.appendChild(li);
      });
    }
    async function openMeeting(sampleId){
      state.selected=sampleId; await loadQueue();
      const data=await api(`/api/meeting/${sampleId}`); const s=data.signals;
      const checks=Object.entries(checklistLabels).map(([key,label])=>`<label><input type="checkbox" id="check-${key}" ${data.reviewChecklist[key]?'checked':''}>${label}</label>`).join('');
      const audios=data.audio.map(item=>`<div class="audio-row"><div class="muted">${esc(item.label)}</div><audio controls preload="metadata" src="/api/audio/${sampleId}/${item.index}"></audio></div>`).join('');
      document.getElementById('main').innerHTML = `
        <section class="toolbar"><h2>Reunião #${data.rank}</h2><div class="signals"><span class="signal">similaridade ${s.sequenceSimilarity.toFixed(3)}</span><span class="signal">razão de palavras ${s.teacherToCurrentWordRatio===null?'—':s.teacherToCurrentWordRatio.toFixed(3)}</span><span class="signal">baixa confiança ${(s.lowConfidenceWordFraction*100).toFixed(1)}%</span></div></section>
        <section class="card"><label>Áudio original</label>${audios}</section>
        <section class="editors">
          <div class="card"><label for="corrected">Transcrição corrigida</label><textarea id="corrected" spellcheck="true"></textarea><div class="muted">Inicia com o rascunho do Whisper Large v3. Edite somente com base no áudio.</div></div>
          <div class="card"><label for="current">Transcrição atual do app · referência ruidosa</label><textarea id="current" readonly></textarea><div class="muted">Use para localizar divergências; não copie sem conferir o áudio.</div></div>
        </section>
        <section class="card review-grid">
          <div><label for="reviewer">Revisor</label><input id="reviewer" maxlength="120" value="${esc(data.reviewer)}"><label for="consent" style="margin-top:14px">Autoridade/consentimento</label><select id="consent"><option value="pending_documentation">Documentação pendente</option><option value="approved_for_private_training">Aprovada para treino privado</option><option value="excluded">Excluída</option></select></div>
          <div><label>Checklist obrigatório para aprovação</label><div class="checks">${checks}</div><label for="notes" style="margin-top:14px">Notas de revisão / motivo de exclusão</label><textarea id="notes" style="min-height:100px"></textarea></div>
        </section>
        <div class="actions"><button class="action danger" onclick="submitReview('exclude')">Excluir</button><button class="action" onclick="submitReview('save')">Salvar rascunho</button><button class="action primary" onclick="submitReview('approve')">Aprovar transcrição</button></div><div class="status" id="status"></div>`;
      document.getElementById('corrected').value=data.correctedTranscript;
      document.getElementById('current').value=data.currentTranscript;
      document.getElementById('notes').value=data.reviewNotes;
      document.getElementById('consent').value=data.consentStatus;
    }
    async function submitReview(decision){
      const status=document.getElementById('status'); status.textContent='Salvando…';
      const checklist={}; Object.keys(checklistLabels).forEach(key=>checklist[key]=document.getElementById(`check-${key}`).checked);
      const payload={ decision, correctedTranscript:document.getElementById('corrected').value, reviewer:document.getElementById('reviewer').value, consentStatus:document.getElementById('consent').value, reviewNotes:document.getElementById('notes').value, reviewChecklist:checklist };
      try { await api(`/api/meeting/${state.selected}`, {method:'POST',body:JSON.stringify(payload)}); status.textContent='Salvo com segurança.'; await loadQueue(); }
      catch(error){ status.textContent=error.message; }
    }
    loadQueue().catch(error=>{ document.getElementById('main').innerHTML=`<div class="empty"><h2>Acesso não autorizado</h2><p>${esc(error.message)}</p></div>`; });
  </script>
</body>
</html>"""


class ReviewHandler(BaseHTTPRequestHandler):
    store: AnnotationStore
    token: str

    def log_message(self, format: str, *args: object) -> None:
        return

    def _security_headers(self) -> None:
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'self'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; "
            "media-src 'self'; connect-src 'self'; frame-ancestors 'none'",
        )

    def _cookie_token(self) -> str | None:
        cookie = self.headers.get("Cookie", "")
        for part in cookie.split(";"):
            name, separator, value = part.strip().partition("=")
            if separator and name == "qapia_review":
                return value
        return None

    def _authorized(self, query: dict[str, list[str]]) -> bool:
        query_token = query.get("token", [None])[0]
        header_token = self.headers.get("X-Qapia-Review-Token")
        supplied = query_token or header_token or self._cookie_token()
        return bool(supplied and secrets.compare_digest(supplied, self.token))

    def _json(self, status: int, payload: dict[str, Any]) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self._security_headers()
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _error(self, status: int, message: str) -> None:
        self._json(status, {"error": message})

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        if not self._authorized(query):
            self._error(HTTPStatus.UNAUTHORIZED, "Token privado inválido ou ausente")
            return
        if parsed.path == "/":
            body = HTML.encode("utf-8")
            self.send_response(HTTPStatus.OK)
            self._security_headers()
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            if query.get("token", [None])[0]:
                self.send_header(
                    "Set-Cookie",
                    f"qapia_review={self.token}; HttpOnly; SameSite=Strict; Path=/",
                )
            self.end_headers()
            self.wfile.write(body)
            return
        if parsed.path == "/api/queue":
            self._json(HTTPStatus.OK, self.store.queue_payload())
            return
        match = re.fullmatch(r"/api/meeting/([a-f0-9]{12})", parsed.path)
        if match:
            try:
                self._json(HTTPStatus.OK, self.store.meeting_payload(match.group(1)))
            except (KeyError, ValueError, OSError, json.JSONDecodeError) as error:
                self._error(HTTPStatus.NOT_FOUND, str(error))
            return
        audio_match = re.fullmatch(r"/api/audio/([a-f0-9]{12})/(\d+)", parsed.path)
        if audio_match:
            try:
                self._serve_audio(
                    self.store.audio_path(audio_match.group(1), int(audio_match.group(2)))
                )
            except (KeyError, ValueError, OSError) as error:
                self._error(HTTPStatus.NOT_FOUND, str(error))
            return
        self._error(HTTPStatus.NOT_FOUND, "Recurso não encontrado")

    def _serve_audio(self, path: Path) -> None:
        size = path.stat().st_size
        start, end = 0, size - 1
        range_header = self.headers.get("Range")
        status = HTTPStatus.OK
        if range_header:
            match = re.fullmatch(r"bytes=(\d*)-(\d*)", range_header.strip())
            if not match:
                self._error(HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE, "Faixa inválida")
                return
            if match.group(1):
                start = int(match.group(1))
            if match.group(2):
                end = min(int(match.group(2)), size - 1)
            if start > end or start >= size:
                self._error(HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE, "Faixa inválida")
                return
            status = HTTPStatus.PARTIAL_CONTENT
        length = end - start + 1
        self.send_response(status)
        self._security_headers()
        self.send_header("Content-Type", mimetypes.guess_type(path.name)[0] or "audio/mp4")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(length))
        if status == HTTPStatus.PARTIAL_CONTENT:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        with path.open("rb") as handle:
            handle.seek(start)
            remaining = length
            try:
                while remaining:
                    block = handle.read(min(1024 * 1024, remaining))
                    if not block:
                        break
                    self.wfile.write(block)
                    remaining -= len(block)
            except (BrokenPipeError, ConnectionResetError):
                return

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        if not self._authorized(parse_qs(parsed.query)):
            self._error(HTTPStatus.UNAUTHORIZED, "Token privado inválido ou ausente")
            return
        if self.headers.get("X-Qapia-Review") != "1":
            self._error(HTTPStatus.FORBIDDEN, "Cabeçalho de revisão ausente")
            return
        match = re.fullmatch(r"/api/meeting/([a-f0-9]{12})", parsed.path)
        if not match:
            self._error(HTTPStatus.NOT_FOUND, "Recurso não encontrado")
            return
        try:
            content_length = int(self.headers.get("Content-Length", "0"))
            if content_length <= 0 or content_length > 10 * 1024 * 1024:
                raise ValueError("Tamanho de revisão inválido")
            payload = json.loads(self.rfile.read(content_length))
            annotation = self.store.save_review(match.group(1), payload)
            self._json(
                HTTPStatus.OK,
                {
                    "saved": True,
                    "asrReviewStatus": annotation["asrReviewStatus"],
                    "consentStatus": annotation["consentStatus"],
                },
            )
        except KeyError as error:
            self._error(HTTPStatus.NOT_FOUND, str(error))
        except (ValueError, TypeError, json.JSONDecodeError) as error:
            self._error(HTTPStatus.BAD_REQUEST, str(error))


def main() -> int:
    args = parse_args()
    if args.host not in {"127.0.0.1", "::1", "localhost"} and not args.allow_non_loopback:
        raise SystemExit("Refusing non-loopback binding without --allow-non-loopback")
    token = load_or_create_token(args.token_file)
    store = AnnotationStore(
        args.queue,
        args.dataset_root,
        args.teacher_root,
        args.annotations_root,
    )
    handler = type(
        "ConfiguredReviewHandler",
        (ReviewHandler,),
        {"store": store, "token": token},
    )
    server = ThreadingHTTPServer((args.host, args.port), handler)
    print(
        json.dumps(
            {
                "status": "ready",
                "bind": f"{args.host}:{args.port}",
                "reviewUrl": f"http://127.0.0.1:{args.port}/?token={token}",
                "classification": "private-sensitive-restricted",
            }
        ),
        flush=True,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
