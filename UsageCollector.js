#!/usr/bin/env node
/*
 * UsageCollector.js —— 汇总 DSH 本地会话的 token 用量与折算花费
 *
 * 为什么用 Node：DSH 的会话日志是 zstd 压缩的（而且是多帧拼接的 seekable 格式），
 * Windows PowerShell 5.1 完全没有 zstd 解压能力，所以借 DSH 自带的 node.exe
 * （v24，内置 zlib.zstdDecompressSync）来干这活。
 *
 * 数据来源：~/.dsh/sessions/<project>/<session-id>/session.v4.jsonl.zstd
 *   每条 type=assistant/message 记录里的 data.usage：
 *     { inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens, totalTokens }
 *   注意 data.stream[*].chunk.usage 是流式分片里的重复值，必须忽略，否则会翻倍。
 *
 * 输出：stdout 一份 JSON（供 PowerShell 读取）
 *
 * 用法：
 *   node UsageCollector.js [--sessions <dir>] [--cache <file>] [--config <config.json>]
 *                          [--days 30] [--pretty]
 */

'use strict';

const fs = require('fs');
const path = require('path');
const os = require('os');
const zlib = require('zlib');

// ------------------------------------------------------------------ 参数

function parseArgs(argv) {
  const out = {
    sessions: path.join(os.homedir(), '.dsh', 'sessions'),
    cache: null,
    config: null,
    days: 30,
    pretty: false,
  };
  for (let i = 2; i < argv.length; i++) {
    const k = argv[i];
    if (k === '--sessions') out.sessions = argv[++i];
    else if (k === '--cache') out.cache = argv[++i];
    else if (k === '--config') out.config = argv[++i];
    else if (k === '--days') out.days = Number(argv[++i]) || 30;
    else if (k === '--out') out.out = argv[++i];
    else if (k === '--pretty') out.pretty = true;
  }
  return out;
}

// 输出结果。优先写文件：PowerShell 捕获子进程 stdout 会受控制台编码/换行宽度影响，
// 而且调用了 2>$null 时任何 stderr 都会污染结果。写文件再读就完全没这些问题。
function emit(result, args) {
  const json = JSON.stringify(result, null, args.pretty ? 2 : 0);
  if (args.out) {
    try {
      fs.writeFileSync(args.out, json, 'utf8');
      return;
    } catch (e) {
      // 写不了文件就退回 stdout
    }
  }
  process.stdout.write(json);
}

// 官方价目表：https://api-docs.deepseek.com/zh-cn/quick_start/pricing/
// 单位：元 / 百万 tokens。这里是「空闲时段」价，高峰时段 = 空闲 × peakMultiplier。
const DEFAULT_PRICING = {
  peakMultiplier: 2,
  tzOffsetHours: 8,
  defaultModel: 'deepseek-flash',
  models: {
    'deepseek-flash': { cacheHit: 0.02, cacheMiss: 1.0, output: 4.0 },
    'deepseek-v4-pro': { cacheHit: 0.15, cacheMiss: 4.5, output: 13.5 },
    // 旧模型名，按 Flash 计费（官方说明：请求由 V4.1-Flash 提供服务）
    'deepseek-v4-flash': { cacheHit: 0.02, cacheMiss: 1.0, output: 4.0 },
  },
  holidays: [], // 形如 ["2026-10-01","2026-10-02"]，高峰判定时排除
};

function loadPricing(configPath) {
  const pricing = JSON.parse(JSON.stringify(DEFAULT_PRICING));
  if (!configPath) return pricing;
  try {
    let text = fs.readFileSync(configPath, 'utf8');
    // PowerShell 的 Set-Content -Encoding UTF8 会带 BOM，JSON.parse 不认，必须先剥掉
    if (text.charCodeAt(0) === 0xfeff) text = text.slice(1);
    const cfg = JSON.parse(text);
    const p = cfg.pricing;
    if (p && typeof p === 'object') {
      if (Array.isArray(p.models)) {
        // 兼容数组写法
      } else if (p.models && typeof p.models === 'object') {
        Object.assign(pricing.models, p.models);
      }
      if (typeof p.peakMultiplier === 'number') pricing.peakMultiplier = p.peakMultiplier;
      if (typeof p.tzOffsetHours === 'number') pricing.tzOffsetHours = p.tzOffsetHours;
      if (p.defaultModel) pricing.defaultModel = p.defaultModel;
      if (Array.isArray(p.holidays)) pricing.holidays = p.holidays;
    }
  } catch (e) {
    pricing.__error = '读取 config.json 失败: ' + e.message;
  }
  return pricing;
}

// ------------------------------------------------------------------ zstd

const ZSTD_MAGIC = Buffer.from([0x28, 0xb5, 0x2f, 0xfd]);

function frameOffsets(buf) {
  const offs = [];
  let i = buf.indexOf(ZSTD_MAGIC, 0);
  while (i !== -1) {
    offs.push(i);
    i = buf.indexOf(ZSTD_MAGIC, i + 4);
  }
  return offs;
}

// 多帧 seekable zstd：逐帧解压再拼接（zstdDecompressSync 只吃第一帧）
function decompressFrames(buf) {
  const parts = [];
  for (const off of frameOffsets(buf)) {
    try {
      parts.push(zlib.zstdDecompressSync(buf.subarray(off)));
    } catch (e) {
      // 文件正在写入时的最后一帧可能不完整，跳过即可
    }
  }
  return Buffer.concat(parts).toString('utf8');
}

// ------------------------------------------------------------------ 解析

function parseSessionFile(file, pricing) {
  const raw = fs.readFileSync(file);
  const text = decompressFrames(raw);
  const records = [];
  for (const line of text.split('\n')) {
    if (!line) continue;
    let o;
    try { o = JSON.parse(line); } catch { continue; }
    if (o.type !== 'assistant/message') continue;
    const u = o.data && o.data.usage;
    if (!u) continue;
    let model = pricing.defaultModel;
    try {
      const m = o.data.message && o.data.message.source && o.data.message.source.model;
      if (m) model = m;
    } catch { }
    records.push([
      o.time || 0,
      model,
      u.inputTokens || 0,
      u.outputTokens || 0,
      u.cacheReadTokens || 0,
      u.cacheWriteTokens || 0,
    ]);
  }
  return records;
}

// ------------------------------------------------------------------ 计价

function beijingParts(timeMs, tzOffsetHours) {
  const d = new Date(timeMs + tzOffsetHours * 3600 * 1000);
  return {
    y: d.getUTCFullYear(),
    m: d.getUTCMonth() + 1,
    day: d.getUTCDate(),
    dow: d.getUTCDay(),      // 0=周日
    hour: d.getUTCHours(),
  };
}

const pad = (n) => (n < 10 ? '0' + n : String(n));

function dateKey(timeMs, pricing) {
  const p = beijingParts(timeMs, pricing.tzOffsetHours);
  return `${p.y}-${pad(p.m)}-${pad(p.day)}`;
}

function isPeak(timeMs, pricing) {
  const p = beijingParts(timeMs, pricing.tzOffsetHours);
  if (p.dow === 0 || p.dow === 6) return false;                 // 周末全天空闲
  if (pricing.holidays.includes(dateKey(timeMs, pricing))) return false;
  const morning = p.hour >= 9 && p.hour < 12;
  const afternoon = p.hour >= 14 && p.hour < 18;
  return morning || afternoon;
}

function priceOf(model, pricing) {
  return pricing.models[model] || pricing.models[pricing.defaultModel] || { cacheHit: 0, cacheMiss: 0, output: 0 };
}

function costOf(rec, pricing) {
  const [, model, input, output, cacheRead, cacheWrite] = rec;
  const p = priceOf(model, pricing);
  const mul = isPeak(rec[0], pricing) ? pricing.peakMultiplier : 1;
  const yuan = (input * p.cacheMiss + cacheRead * p.cacheHit + output * p.output + cacheWrite * p.cacheMiss) / 1e6;
  return yuan * mul;
}

// ------------------------------------------------------------------ 缓存

function loadCache(file) {
  if (!file) return { version: 1, files: {} };
  try {
    const c = JSON.parse(fs.readFileSync(file, 'utf8'));
    if (c && c.version === 1 && c.files) return c;
  } catch { }
  return { version: 1, files: {} };
}

function saveCache(file, cache) {
  if (!file) return;
  try {
    fs.writeFileSync(file, JSON.stringify(cache), 'utf8');
  } catch { }
}

// ------------------------------------------------------------------ 主流程

function findSessionFiles(root) {
  const found = [];
  const walk = (dir, depth) => {
    if (depth > 3) return;
    let entries;
    try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
    for (const e of entries) {
      const full = path.join(dir, e.name);
      if (e.isDirectory()) walk(full, depth + 1);
      else if (e.isFile() && e.name.endsWith('.jsonl.zstd')) found.push(full);
    }
  };
  walk(root, 0);
  return found;
}

function main() {
  const args = parseArgs(process.argv);
  const pricing = loadPricing(args.config);
  const result = {
    ok: false,
    generatedAt: Date.now(),
    sessionsDir: args.sessions,
    files: { total: 0, parsed: 0, cached: 0, failed: 0 },
    today: null,
    days: [],
    models: {},
    totals: { cost: 0, inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0, totalTokens: 0, requests: 0 },
    errors: [],
    pricing: { source: 'DeepSeek 官方价目表（空闲价，高峰×' + pricing.peakMultiplier + '）', models: Object.keys(pricing.models) },
  };
  if (pricing.__error) result.errors.push(pricing.__error);

  if (typeof zlib.zstdDecompressSync !== 'function') {
    result.errors.push('当前 node (' + process.version + ') 不支持 zstd，需要 >= 22.15 或 >= 23.8');
    emit(result, args);
    process.exit(2);
  }

  const cache = loadCache(args.cache);
  const files = findSessionFiles(args.sessions);
  result.files.total = files.length;

  const allRecords = [];
  const seen = new Set();

  for (const f of files) {
    seen.add(f);
    let stat;
    try { stat = fs.statSync(f); } catch { continue; }
    const entry = cache.files[f];
    if (entry && entry.size === stat.size && entry.mtimeMs === stat.mtimeMs) {
      result.files.cached++;
      for (const r of entry.records) allRecords.push(r);
      continue;
    }
    try {
      const records = parseSessionFile(f, pricing);
      cache.files[f] = { size: stat.size, mtimeMs: stat.mtimeMs, records };
      result.files.parsed++;
      for (const r of records) allRecords.push(r);
    } catch (e) {
      result.files.failed++;
      result.errors.push(path.basename(path.dirname(f)) + ': ' + e.message);
    }
  }

  // 清理已消失文件的缓存
  for (const k of Object.keys(cache.files)) if (!seen.has(k)) delete cache.files[k];
  saveCache(args.cache, cache);

  // 按天聚合（保留最近 N 天）
  const cutoff = Date.now() - args.days * 86400 * 1000;
  const byDay = new Map();
  const byModel = new Map();
  for (const r of allRecords) {
    if (!r[0] || r[0] < cutoff) continue;
    const day = dateKey(r[0], pricing);
    let d = byDay.get(day);
    if (!d) {
      d = { date: day, cost: 0, inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0, totalTokens: 0, requests: 0, peakRequests: 0 };
      byDay.set(day, d);
    }
    const cost = costOf(r, pricing);
    d.cost += cost;
    d.inputTokens += r[2];
    d.outputTokens += r[3];
    d.cacheReadTokens += r[4];
    d.cacheWriteTokens += r[5];
    d.totalTokens += r[2] + r[3] + r[4] + r[5];
    d.requests += 1;
    if (isPeak(r[0], pricing)) d.peakRequests += 1;

    let m = byModel.get(r[1]);
    if (!m) { m = { model: r[1], cost: 0, requests: 0, inputTokens: 0, outputTokens: 0, cacheReadTokens: 0 }; byModel.set(r[1], m); }
    m.cost += cost; m.requests += 1;
    m.inputTokens += r[2]; m.outputTokens += r[3]; m.cacheReadTokens += r[4];
  }

  const todayKey = dateKey(Date.now(), pricing);
  if (!byDay.has(todayKey)) {
    byDay.set(todayKey, { date: todayKey, cost: 0, inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0, totalTokens: 0, requests: 0, peakRequests: 0 });
  }

  result.today = byDay.get(todayKey);
  result.today.offPeakRequests = result.today.requests - result.today.peakRequests;
  result.days = [...byDay.values()].sort((a, b) => (a.date < b.date ? -1 : 1));
  for (const d of result.days) d.offPeakRequests = d.requests - d.peakRequests;
  result.models = Object.fromEntries([...byModel.entries()]);

  const t = result.totals;
  for (const d of result.days) {
    t.cost += d.cost; t.inputTokens += d.inputTokens; t.outputTokens += d.outputTokens;
    t.cacheReadTokens += d.cacheReadTokens; t.cacheWriteTokens += d.cacheWriteTokens;
    t.totalTokens += d.totalTokens; t.requests += d.requests;
  }
  // 保留 6 位小数，避免浮点噪声
  result.today.cost = Number(result.today.cost.toFixed(6));
  for (const d of result.days) d.cost = Number(d.cost.toFixed(6));
  for (const k of Object.keys(result.models)) result.models[k].cost = Number(result.models[k].cost.toFixed(6));
  t.cost = Number(t.cost.toFixed(6));

  result.ok = true;
  emit(result, args);
}

const __args = parseArgs(process.argv);
try {
  main();
} catch (e) {
  emit({ ok: false, errors: ['collector 崩溃: ' + e.message + '\n' + e.stack] }, __args);
  process.exit(1);
}
