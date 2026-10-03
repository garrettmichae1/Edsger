# Local document chat

Implemented 2026-10-03. No Pro entitlement is enforced in this version.

## User flow

Open **+ → Files** in chat. The Add files sheet has Upload files, a searchable
Recent grid with text previews and selection circles, and a close action.
Importing or selecting a recent file attaches it to the current draft. The composer
shows a compact filename pill: tap its name to preview, or × to leave file context.
A file without a typed question sends a request for an overview. Tap an attachment to inspect extracted text or Quick Look the
original. Long-press a Recent card to delete the imported file.

Each message can attach one document. A thread can contain multiple documents.
The **most recently attached document** supplies subsequent answers; the composer
shows its name in the pill. Tap × to return to ordinary chat in the same thread.
Earlier attachments, answers and source passages remain visible, and the imported
original is kept. Active document context is cleared persistently per conversation;
future inference starts after the cleared document turns. Removing only an unsent
attachment preserves earlier ordinary-chat inference context.

Clearing during generation stops the response, retaining any partial answer and
the next draft. The composer offers **Document context cleared → Undo**, restoring
the previous active context and any pending replacement file. Undo does not resume
cancelled generation. It is available until sending, selecting a file, changing
conversations, or relaunching; the cleared state itself survives relaunch. Retrying
an old turn cannot reactivate context after clearing it. Conversation activity
order is not changed by Clear or Undo.

Select an earlier file from Recent and send it again to switch back or resume it.
Starting a new chat clears active document context. This version does not
combine or compare separate files in one answer.

Attachment drafts survive conversation switches and relaunch, including drafts
with no typed text. History marks these as drafts and searches attachment names.
Saved user messages retain attachment metadata; assistant messages retain the
actual passages supplied to that answer. Source buttons open those passages.
Deleting an imported file does not erase saved answers or passages, but it makes
new questions about that file unavailable until it is imported again.

## Supported input and limits

| Input | Extraction | Limitations |
| --- | --- | --- |
| TXT | UTF-8 or BOM-marked UTF-16 | Invalid encodings, binary controls and unusually oversized graphemes are rejected. |
| MD / Markdown | Plain source text | Images and links are not fetched; no rendered Markdown interpretation. |
| PDF | PDFKit text for each page | Locked, invalid, or any page without readable text is rejected. No OCR, handwriting, chart or equation interpretation. Complex column ordering may be imperfect. |
| DOCX | Main WordprocessingML body and table cell text | Strict and transitional namespaces supported. Deleted tracked text is excluded and inserted text retained. Headers, footnotes, drawings/text boxes, images, formatting and layout are not analyzed. Equations, embedded objects and alternative content imports are rejected. |

Old `.doc`, RTF, spreadsheets, slide decks, images and scanned documents are not
included in the first release. Files are not sent to a server.

| Budget | Enforced bound |
| --- | --- |
| Original file | 10 MiB |
| Extracted text | 50,000 characters |
| PDF | 25 pages |
| Recent library | 50 files / 100 MiB of originals |
| DOCX archive | 2,000 entries / 50 MiB advertised expansion |
| Main DOCX XML | 2 MiB, depth 128 |
| Document question | 2,000 UTF-8 bytes |
| Evidence per answer | Up to four excerpts, 650 UTF-8 bytes each, 2,600 total |
| Prior file conversation | Last two messages, each clipped to 500 UTF-8 bytes |

Limits reject files rather than silently accepting a truncated extraction.
Question validation preserves the user's draft and pending attachment.

## Architecture and speed

`ChatDocumentStore` is an actor owning UUID-named folders under Application
Support/lilC/ChatDocuments. It coordinates security-scoped file-provider reads,
reads in bounded chunks, snapshots the original, extracts once, and atomically
writes normalized text and metadata. Failed imports clean up their new folder.
Protected writes use the same iOS file-protection level as chat storage.

DOCX uses **ZIPFoundation 0.9.20**, pinned to commit
`22787ffb59de99e5dc1fbfe80b19c97a904ad48d`. Only `word/document.xml` is extracted
into bounded memory; no archive paths are written to disk. Duplicate paths,
non-file document entries, excess expansion and checksum mismatches are rejected.
XML external resolution is disabled; entity/DTD declarations are rejected before
parsing and by declaration callbacks. The bundled MIT notice is in Settings →
Licenses. Upstream: <https://github.com/weichsel/ZIPFoundation/tree/0.9.20>.

`DocumentRetrieval` divides text into overlapping byte-bounded passages. It ranks
lexical matches using inverse term frequency and supplies no more than four
passages. Very short follow-ups also use the previous question's terms. Overviews
sample passages across the file. A question without matching evidence returns a
clear refinement request without calling the model. There is no embedding model,
second inference context, or persistent cache containing every document's text.

`DocumentTutorClient` forwards ordinary conversations to the existing calculator /
chat client unchanged. Document answers use one bounded synthesized prompt in the
user's selected Edsger model. The last attached file defines the evidence boundary:
text and prior answers from earlier files are not included. `SelectedChatClient`
holds the existing model-choice lease across the reply and releases it on success
or failure. Source callbacks are awaited and guarded by the session run ID, so
cancellation or chat switching cannot write sources into a different reply.

An eight-second cooperative import budget checks between file chunks, ZIP chunks
and PDF pages, plus cancellation checks. It is **not a hard deadline** around an
individual PDFKit, XML parser, filesystem or file-provider operation. Native model
loading is also not interruptible partway through. These limits constrain work;
they cannot promise instant answers on every iPhone or pathological file.

## Accuracy boundaries

The model receives selected evidence, not every document in a thread or necessarily
every paragraph of a long file. The prompt instructs it to cite supplied passages,
acknowledge missing evidence and limit overviews to those passages. The UI labels
these as selected passages; they are inspectable evidence, not verification of
every generated claim. Lexical retrieval can miss paraphrases and synonyms.

Document content is JSON-encoded as untrusted quoted data, with instructions to
ignore embedded directives. This reduces prompt confusion; it does not guarantee
that a generative model will obey every instruction. Document prompts have no
project tools, file-writing capability or browsing. Neither file links nor XML
external entities are followed.

Document answers retain the existing math/Markdown renderer, but do **not** run the
SymPy calculator. Their prompt forbids claiming calculator verification. Normal
chat calculations still use the established SymPy path. Extraction does not make
scanned or visually laid-out mathematics understandable.

## Validation

Executed on a Linux Swift 6.0.3 host:

- Production text/XML/ZIP extraction, corruption and CRC rejection, duplicate and
  symlink entries, oversize inputs, encodings, cancellation, failed-import cleanup,
  library quotas, catalog reopen and deletion.
- Retrieval at the end of long and multilingual files, bounded source bytes,
  follow-ups, no-match model bypass and active-file isolation.
- Production session attachment drafts, switching, source persistence, old JSON
  compatibility, attachment-only send and stale callbacks after cancellation.
- Clear/Undo restores pending and active files, preserves messages/drafts/originals,
  survives relaunch/switching, returns to ordinary routing, handles unsent files and
  rejects late callbacks when clearing during generation.
- Existing chat-experience, model-selection, prompt-cache and ten math-domain
  regressions; Xcode source/product/license membership and immutable package pins.
- Swift 6 integration typecheck with the real SelectedChatClient and document
  components. Apple logging, hashing and calculator dependencies were host stubs
  for this compile-only check; it does not test their implementation.
- Four real-model answers with the production evidence prompt, two each on Mini
  and Standard. Both returned the supplied cancellation fee and renewal deadline
  with [1] citations. This is a wiring smoke test, not an accuracy benchmark.

Representative host measurements from those smoke checks:

| Work | Time |
| --- | --- |
| Retrieve rare term near end of 49,314 characters | About 17 ms |
| Mini first document reply, including cold load | 5.36 s total / 5.12 s first token |
| Mini next reply | 0.86 s total / 0.59 s first token |
| Standard first document reply, including cold load | 17.71 s total / 16.86 s first token |
| Standard next reply | 2.64 s total / 1.87 s first token |

These are CPU host measurements, not iPhone performance guarantees.

Reproduce portable checks with `bash scripts/test-chat-documents.sh`; it resolves
the exact ZIPFoundation version. An optional `EDSGER_ZIPFOUNDATION_PATH` can point
to an existing checkout of that revision. Existing regression scripts remain in
`scripts`. `bash scripts/test-document-model.sh MINI_GGUF STANDARD_GGUF` runs real
model checks on macOS with the existing llama framework.

Added `ChatDocumentPDFTests` for native text/scan/page-limit extraction and
`testFilesSheetOpensSearchesAndCloses` for the native Files UI. Their syntax was
parsed here, but they were **not run**: this host has no Xcode, PDFKit or SwiftUI
SDK. Before release, build in Xcode and run them, then verify on iPhone/iPad:

1. Light/dark appearance, large Dynamic Type, VoiceOver, keyboard, rotation and
   Files-provider cancellation / offline downloads.
2. Real exported DOCX tables, UTF-16 TXT and PDFs with columns, blank pages,
   encryption, Unicode and complex formatting; confirm preview and source labels.
3. Import A, follow up, attach B, reopen, reselect A, stop a streamed reply and
   clear context during a reply, Undo, and delete a recent file. Confirm drafts,
   thread isolation, saved passages and the pill's preview/clear accessibility.
4. Measure import, first-token time and peak memory on the oldest supported device
   with both models, near-limit files, memory pressure and cold/warm starts.
5. Recheck ordinary math, chat formatting, history pinning and IDE run/agent flows.
