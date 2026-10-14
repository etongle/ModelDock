// Exercise Pi's installed compaction implementation on a copy of the failed
// session. Never append to the user's live transcript or execute model tools.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";
import assert from "node:assert/strict";
import { SessionManager } from "/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/dist/core/session-manager.js";
import { compact, prepareCompaction } from "/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/dist/core/compaction/compaction.js";
import { streamSimple } from "/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/@earendil-works/pi-ai/dist/compat.js";
const profile = path.resolve(process.argv[2]);
const reportPath = path.resolve(process.argv[3]);
const settings = { enabled: true, reserveTokens: 12288, keepRecentTokens: 2048 };
const providerID = "model-manager-8001";
const config = JSON.parse(fs.readFileSync(path.join(profile, "models.json"), "utf8"));
const provider = config.providers[providerID];
assert.equal(provider.baseUrl, "http://127.0.0.1:8001/v1");
const model = { ...provider.models[0], provider: providerID, api: provider.api, baseUrl: provider.baseUrl, compat: provider.compat,
  maxTokens: 8192, samplingParams: { chat_template_kwargs: { enable_thinking: false } } };
assert.equal(model.contextWindow, 32768);
const sessions = fs.readdirSync(path.join(profile, "sessions/--Users-null--")).filter(name => name.endsWith(".jsonl"));
const original = sessions.map(name => path.join(profile, "sessions/--Users-null--", name)).sort((a,b) => fs.statSync(b).mtimeMs - fs.statSync(a).mtimeMs)[0];
assert.ok(original);
const bytes = fs.readFileSync(original), beforeHash = crypto.createHash("sha256").update(bytes).digest("hex");
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), "model-manager-pi-compaction-"));
fs.chmodSync(temporary, 0o700);
const copy = path.join(temporary, "session.jsonl"); fs.writeFileSync(copy, bytes, {mode:0o600});
const manager = SessionManager.open(copy);
const preparation = prepareCompaction(manager.getBranch(), settings);
assert.ok(preparation, "The failed session has nothing to compact");
const calls = [];
const stream = (selected, context, options) => streamSimple(selected, context, { ...options, onPayload: payload => {
  assert.equal(payload.chat_template_kwargs?.enable_thinking, false);
  calls.push({ maxTokens: payload.max_tokens, messageCount: payload.messages.length, thinkingDisabled: true });
  return payload;
} });
console.log("Testing installed Pi compaction with isolated session copy...");
const result = await compact(preparation, model, provider.apiKey, undefined,
  "Keep a concise checkpoint. Preserve the user's request, completed work, unresolved work, and key file paths. Do not repeat tool output or add new tasks. Limit the checkpoint to 800 words.",
  AbortSignal.timeout(240000), "off", stream);
assert.ok(result.summary.trim().length > 0);
assert.ok(calls.length > 0 && calls.every(call => call.maxTokens >= 4096 && call.maxTokens <= 8192));
assert.ok(!result.usage?.reasoning, "The summary still used thinking tokens");
manager.appendCompaction(result.summary, result.firstKeptEntryId, result.tokensBefore, result.details, false, result.usage);
const after = manager.buildSessionProjection();
assert.ok(after.messages.length < preparation.messagesToSummarize.length + preparation.turnPrefixMessages.length + 10);
// Only compare if the live file did not change while the user was typing.
const currentHash = crypto.createHash("sha256").update(fs.readFileSync(original)).digest("hex");
const report = { result: "passed", model: model.id, context: model.contextWindow, settings, requests: calls,
  summaryCharacters: result.summary.length, summaryUsage: result.usage, tokensBefore: result.tokensBefore,
  projectedMessagesAfter: after.messages.length, originalSessionUnchanged: currentHash === beforeHash,
  originalSessionWritten: false, toolsExecuted: false, modelServiceRestarted: false };
fs.mkdirSync(path.dirname(reportPath), {recursive:true});
fs.writeFileSync(reportPath, JSON.stringify(report, null, 2));
console.log(JSON.stringify(report));
// The transient copy contains private conversation content; leave only counts.
fs.rmSync(temporary, {recursive:true, force:true});
