# Lessons Learned - Terminology Verification

## Findings on Taiwan Technology Terminology
- **template**: In Taiwan, "範本" is used for files/documents/spreadsheets/presentations, whereas "樣板" is preferred in software development (e.g. C++ templates, template engines).
- **process**: In CS/OS contexts, "行程" or "處理程序" is standard. "程序" can lead to confusion with "程式" (program) or "程序" (procedure/steps).
- **identifier**: Translated as "識別碼" (for unique IDs), or "識別字" / "識別符" (for syntax elements/tokens). "識別" is too generic.
- **closed loop**: "閉迴路" is standard in control systems, and "封閉迴圈" is used in ecology/business cycles.
- **iteration**: Both "迭代" and "疊代" are widely used, but "疊代" is the standard recommended by the National Academy for Educational Research (NAER).
- **tech stack**: Translated as "技術堆疊" (standard) or "技術組合", but directly using "tech stack" is extremely common and natural in Taiwan software industry. Avoid using "技術棧" (CN).

## Antigravity CLI Data Sources
- Modern Antigravity CLI uses SQLite databases (`~/.gemini/antigravity-cli/conversations/*.db`) and transcripts (`~/.gemini/antigravity-cli/brain/*/.system_generated/logs/transcript.jsonl`) for conversation data, rather than obsolete JSONL files in `~/.gemini/tmp`.
- `conversation_summaries.db` stores conversation lifecycle metadata and timestamps, while binary SQLite blobs in `conversations/*.db` store Protobuf trajectory steps.
- Token counts and timestamps are best extracted from brain `transcript.jsonl` files and cross-referenced with SQLite `gen_metadata` for model names.
