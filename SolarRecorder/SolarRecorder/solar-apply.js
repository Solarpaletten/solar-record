#!/usr/bin/env node
// solar-apply.js v3.1 — Solar Dev Pipeline
// ═══════════════════════════════════════════════════════════════
//
// PIPELINE:
//   1. Pre-Deploy Audit  — NEW / PATCH / IDENTICAL / dirs
//   2. Controlled Apply  — diff + backup per file
//   3. Dependency Check  — pnpm install if needed
//   4. TypeScript Scan   — ALL errors at once (tsc --noEmit)
//   5. Architect Decision — Y/N
//   6. Build             — pnpm build
//   7. Verification      — checkpoints from verification.json
//   8. History / Bundle  — .solar-history + .solar-bundles
//   9. Git (3-phase)     — commit → push → optional override
//
// CHANGES IN v3.1 (Sprint 4C.9):
//   • git step is now 3 phases: commit Y/N, push Y/N, override target branch
//   • auto-detects current branch (no more hardcoded origin/main push)
//   • WARNS loudly if currentBranch is main/master and requires typed confirm
//   • NEVER `git add .` — stages ONLY sprint-declared files
//     (report.created + report.modified); other working-tree changes left alone
//   • Lists what will NOT be staged so Architect can see exclusions
//
// READLINE RULE: rl closes ONCE at the very end of main()
//
// USAGE:
//   node solar-apply.js task59_clean.tar.gz
//   node solar-apply.js task59_clean.tar.gz --auto
//   node solar-apply.js task59_clean.tar.gz --dry
//   node solar-apply.js task59_clean.tar.gz --no-build
//   node solar-apply.js task59_clean.tar.gz --no-bundle
//   node solar-apply.js task59             --rollback
//   node solar-apply.js                    --history
// ═══════════════════════════════════════════════════════════════

const fs       = require('fs');
const path     = require('path');
const readline = require('readline');
const { execSync, spawnSync } = require('child_process');

// ─── Args ─────────────────────────────────────────────────────
const ARCHIVE    = process.argv[2];
const AUTO       = process.argv.includes('--auto');
const DRY_RUN    = process.argv.includes('--dry');
const NO_BUILD   = process.argv.includes('--no-build');
const NO_BUNDLE  = process.argv.includes('--no-bundle');
const ROLLBACK   = process.argv.includes('--rollback');
const HISTORY    = process.argv.includes('--history');
const PORT       = process.env.PORT || '3000';

const ROOT        = process.cwd();
const BACKUP_DIR  = path.join(ROOT, '.solar-backups');
const HISTORY_DIR = path.join(ROOT, '.solar-history');
const BUNDLE_DIR  = path.join(ROOT, '.solar-bundles');

// ─── Colors ───────────────────────────────────────────────────
const C = {
  reset:  '\x1b[0m',  red:    '\x1b[31m',
  green:  '\x1b[32m', yellow: '\x1b[33m',
  blue:   '\x1b[34m', cyan:   '\x1b[36m',
  bold:   '\x1b[1m',  dim:    '\x1b[2m',
};
const c   = (clr, s) => `${clr}${s}${C.reset}`;
const sep = (ch = '─', n = 52) => c(C.dim, ch.repeat(n));

// ─── SAFE readline — ONE instance, closed ONCE at end ─────────
const rl  = readline.createInterface({ input: process.stdin, output: process.stdout });
const ask = (q) => new Promise(r => rl.question(q, r));

function closeRL() {
  try { rl.close(); } catch {}
}

// ─── Diff helpers ─────────────────────────────────────────────
function countDiffLines(oldTxt, newTxt) {
  const t1 = `/tmp/sdp_a_${Date.now()}`;
  const t2 = `/tmp/sdp_b_${Date.now()}`;
  fs.writeFileSync(t1, oldTxt);
  fs.writeFileSync(t2, newTxt);
  let added = 0, removed = 0;
  try {
    execSync(`diff ${t1} ${t2}`, { encoding: 'utf-8' });
  } catch (e) {
    for (const l of (e.stdout || '').split('\n')) {
      if (l.startsWith('>')) added++;
      else if (l.startsWith('<')) removed++;
    }
  } finally {
    try { fs.unlinkSync(t1); fs.unlinkSync(t2); } catch {}
  }
  return { added, removed };
}

function showColorDiff(oldTxt, newTxt) {
  const t1 = `/tmp/sdp_c_${Date.now()}`;
  const t2 = `/tmp/sdp_d_${Date.now()}`;
  fs.writeFileSync(t1, oldTxt);
  fs.writeFileSync(t2, newTxt);
  try {
    execSync(`diff -u ${t1} ${t2}`, { encoding: 'utf-8' });
  } catch (e) {
    for (const l of (e.stdout || '').split('\n').slice(2)) {
      if      (l.startsWith('+'))  process.stdout.write(c(C.green,  l) + '\n');
      else if (l.startsWith('-'))  process.stdout.write(c(C.red,    l) + '\n');
      else if (l.startsWith('@@')) process.stdout.write(c(C.cyan,   l) + '\n');
      else                         process.stdout.write(c(C.dim,    l) + '\n');
    }
  } finally {
    try { fs.unlinkSync(t1); fs.unlinkSync(t2); } catch {}
  }
}

// ─── Extract ──────────────────────────────────────────────────
function extract(archivePath) {
  const tmp = `/tmp/sdp_${Date.now()}`;
  fs.mkdirSync(tmp, { recursive: true });
  execSync(`tar -xzf "${archivePath}" -C "${tmp}" --strip-components=1`, { stdio: 'pipe' });
  return tmp;
}

// ─── Collect files ────────────────────────────────────────────
const SKIP = new Set(['.gitignore', 'INSTALL.md', 'solar-apply.js',
                      'solar-deploy.js', 'bundle.js', 'README_DEPLOY.txt']);

function collectFiles(dir, base = dir, out = []) {
  for (const e of fs.readdirSync(dir)) {
    if (SKIP.has(e)) continue;
    const full = path.join(dir, e);
    if (fs.statSync(full).isDirectory()) collectFiles(full, base, out);
    else out.push(path.relative(base, full));
  }
  return out;
}

// ─── Backup ───────────────────────────────────────────────────
function backup(rel, taskName) {
  const src = path.join(ROOT, rel);
  if (!fs.existsSync(src)) return;
  const dst = path.join(BACKUP_DIR, taskName, rel);
  fs.mkdirSync(path.dirname(dst), { recursive: true });
  fs.copyFileSync(src, dst);
}

// ─── Rollback ─────────────────────────────────────────────────
function doRollback(taskName) {
  const bkDir = path.join(BACKUP_DIR, taskName);
  if (!fs.existsSync(bkDir)) {
    console.log(c(C.red, `\n❌ No backup found: ${taskName}`));
    const av = fs.existsSync(BACKUP_DIR) ? fs.readdirSync(BACKUP_DIR).join(', ') : 'none';
    console.log(c(C.dim, `   Available: ${av}`));
    return;
  }
  const files = collectFiles(bkDir);
  for (const f of files) {
    const dst = path.join(ROOT, f);
    fs.mkdirSync(path.dirname(dst), { recursive: true });
    fs.copyFileSync(path.join(bkDir, f), dst);
    console.log(c(C.yellow, `   ↩  ${f}`));
  }
  console.log(c(C.green, `\n✅ Rollback done: ${files.length} files restored\n`));
}

// ─── Step 3: Dependency Check ─────────────────────────────────
async function ensureNodeModules() {
  const nmPath = path.join(ROOT, 'node_modules');
  if (fs.existsSync(nmPath)) return true;

  console.log('\n' + sep() + '\n' + c(C.yellow, '📦 node_modules not found\n'));
  const ans = (await ask(c(C.bold, '   Run pnpm install? [Y] yes  [N] skip  > '))).toLowerCase().trim();
  if (ans === 'n') {
    console.log(c(C.dim, '   Skipped. Build may fail without dependencies.\n'));
    return false;
  }
  console.log('');
  const r = spawnSync('pnpm', ['install'], { cwd: ROOT, stdio: 'inherit', shell: true });
  if (r.status !== 0) {
    console.log(c(C.red, '\n❌ pnpm install FAILED\n'));
    return false;
  }
  console.log(c(C.green, '\n✅ pnpm install done\n'));
  return true;
}

// ─── Step 4: TypeScript Full Scan ─────────────────────────────
function runTypeCheck() {
  console.log('\n' + sep() + '\n' + c(C.bold, '🔍 TypeScript full scan (tsc --noEmit)\n'));

  const r = spawnSync('npx', ['tsc', '--noEmit', '--pretty', 'false'], {
    cwd:      ROOT,
    stdio:    'pipe',
    shell:    true,
    encoding: 'utf-8',
  });

  if (r.status === 0) {
    console.log(c(C.green, '✅ No TypeScript errors — clean!\n'));
    return { passed: true, errors: [], count: 0 };
  }

  const raw    = (r.stdout || '') + (r.stderr || '');
  const errors = [];
  const seen   = new Set();

  for (const line of raw.split('\n')) {
    const m = line.match(/^(.+?)\((\d+),\d+\): error (TS\d+): (.+)/);
    if (m) {
      const key = `${m[1]}:${m[2]}`;
      if (!seen.has(key)) {
        seen.add(key);
        errors.push({
          file:    m[1].replace(ROOT + '/', '').replace(ROOT + '\\', ''),
          line:    parseInt(m[2]),
          code:    m[3],
          message: m[4].trim(),
        });
      }
    }
  }

  const fileCount = new Set(errors.map(e => e.file)).size;

  console.log(sep('─'));
  console.log(c(C.red, `❌ Found ${errors.length} TypeScript error(s) in ${fileCount} file(s):\n`));

  errors.forEach((e, i) => {
    console.log(c(C.bold,   `[${String(i + 1).padStart(2)}] ${e.file}:${e.line}`));
    console.log(c(C.yellow, `      ${e.code}`));
    console.log(c(C.dim,    `      ${e.message}`));
    console.log('');
  });

  console.log(sep('─'));
  console.log(c(C.dim, `   ${errors.length} error(s) in ${fileCount} file(s)`));
  console.log(c(C.dim,   '   Note: these may be pre-existing issues, not from this task\n'));

  return { passed: false, errors, count: errors.length };
}

// ─── Step 6: Build ────────────────────────────────────────────
function runBuildSync(taskName) {
  console.log('\n' + sep() + '\n' + c(C.bold, '⚡ pnpm build\n'));
  const r = spawnSync('pnpm', ['build'], { cwd: ROOT, stdio: 'inherit', shell: true });
  if (r.status === 0) {
    console.log(c(C.green, '\n✅ Build PASSED\n'));
    return true;
  }
  console.log(c(C.red, '\n❌ Build FAILED'));
  console.log(c(C.dim, `   Rollback: node solar-apply.js ${taskName} --rollback\n`));
  return false;
}

// ─── Health check ─────────────────────────────────────────────
function healthCheck() {
  try {
    execSync(`curl -sf http://localhost:${PORT}/api/health`, { timeout: 3000, stdio: 'pipe' });
    return true;
  } catch {
    return false;
  }
}

// ─── History ──────────────────────────────────────────────────
function showHistory() {
  if (!fs.existsSync(HISTORY_DIR)) { console.log('No history yet.'); return; }
  const files = fs.readdirSync(HISTORY_DIR).filter(f => f.endsWith('.json')).sort();
  console.log(c(C.bold, '\n📋 Solar Deploy History\n') + sep());
  for (const f of files) {
    const h     = JSON.parse(fs.readFileSync(path.join(HISTORY_DIR, f), 'utf-8'));
    const build = h.build === 'passed' ? c(C.green, '✅') : h.build === 'failed' ? c(C.red, '❌') : c(C.dim, '○');
    const ts    = h.ts_errors > 0 ? c(C.yellow, ` TS:${h.ts_errors}`) : c(C.green, ' TS:0');
    console.log(`  ${build}${ts}  ${c(C.bold, (h.task || f).padEnd(20))}  +${h.files_created} ~${h.files_modified}  ${c(C.dim, (h.timestamp || '').slice(0, 16))}`);
  }
  console.log('');
}

// ─── Save history ─────────────────────────────────────────────
function saveHistory(taskName, data) {
  fs.mkdirSync(HISTORY_DIR, { recursive: true });
  fs.writeFileSync(
    path.join(HISTORY_DIR, `${taskName}.json`),
    JSON.stringify({ task: taskName, timestamp: new Date().toISOString(), ...data }, null, 2)
  );
}

// ─── Bundle ───────────────────────────────────────────────────
function createBundle(taskName, report, buildPassed) {
  fs.mkdirSync(BUNDLE_DIR, { recursive: true });

  const readmePath = path.join(ROOT, 'README_DEPLOY.txt');
  fs.writeFileSync(readmePath, [
    `Solar ERP — Deploy Bundle`,
    `${'═'.repeat(40)}`,
    `Task:   ${taskName}`,
    `Status: ${buildPassed ? 'SUCCESS' : 'BUILD FAILED'}`,
    `Date:   ${new Date().toISOString().slice(0, 16).replace('T', ' ')}`,
    ``,
    `Files created:  ${report.created.length}`,
    `Files modified: ${report.modified.length}`,
    ``,
    `Run:  pnpm install && pnpm dev`,
  ].join('\n'));

  const outPath = path.join(BUNDLE_DIR, `after_${taskName}.tar.gz`);
  const ex = [
    '--exclude=.git', '--exclude=node_modules', '--exclude=.next',
    '--exclude=dist', '--exclude=.env', '--exclude=.env.*',
    '--exclude=.env.local', '--exclude=.solar-backups',
    '--exclude=.solar-bundles', '--exclude=.solar-history',
    '--exclude=*.log', '--exclude=.DS_Store', '--exclude=tmp',
    '--exclude=pnpm-lock.yaml',
  ].join(' ');
  execSync(`tar -czf "${outPath}" ${ex} -C "${ROOT}" .`, { stdio: 'pipe' });
  try { fs.unlinkSync(readmePath); } catch {}

  const kb = (fs.statSync(outPath).size / 1024).toFixed(1);
  return { path: outPath, kb };
}

// ─── Deploy Report ────────────────────────────────────────────
function printReport(taskName, report, buildResult, tsResult, bundleInfo) {
  const ok   = c(C.green, '✅');
  const fail = c(C.red,   '❌');
  const skip = c(C.dim,   '○');

  console.log('\\n' + sep('━'));
  console.log(c(C.bold, `🚀 TASK ${taskName.toUpperCase()} — DEPLOY REPORT`));
  console.log(sep('━'));

  console.log(`\n   📁 New:        ${c(C.green,  String(report.created.length).padStart(3))}`);
  console.log(`   🔧 Modified:   ${c(C.yellow, String(report.modified.length).padStart(3))}`);
  console.log(`   📂 New dirs:   ${c(C.blue,   String(report.dirs.length).padStart(3))}`);
  console.log(`   ⏭  Skipped:    ${c(C.dim,    String(report.skipped).padStart(3))}`);

  if (report.created.length > 0) {
    console.log('\n' + sep() + '\n' + c(C.bold, '📁 CREATED:'));
    report.created.forEach(f => console.log(c(C.green,  `   + ${f}`)));
  }
  if (report.modified.length > 0) {
    console.log('\n' + sep() + '\n' + c(C.bold, '🔧 MODIFIED:'));
    report.modified.forEach(f => console.log(c(C.yellow, `   ~ ${f}`)));
  }
  if (report.diffSummary.length > 0) {
    console.log('\n' + sep() + '\n' + c(C.bold, '🧾 DIFF:'));
    report.diffSummary.forEach(d => {
      console.log(`   ~ ${path.basename(d.file).padEnd(36)} ${c(C.green, '+' + d.added)} ${c(C.red, '-' + d.removed)}`);
    });
  }
  if (report.modified.length > 0) {
    console.log('\n' + sep() + '\n' + c(C.bold, '💾 BACKUP:'));
    console.log(c(C.green, `   ✔ ${report.modified.length} files → .solar-backups/${taskName}/`));
    console.log(c(C.dim,   `   Rollback: node solar-apply.js ${taskName} --rollback`));
  }

  console.log('\n' + sep() + '\n' + c(C.bold, '🔍 TYPESCRIPT:'));
  if (tsResult === null) {
    console.log(`   ${skip} skipped`);
  } else if (tsResult.passed) {
    console.log(`   ${ok} 0 errors`);
  } else {
    console.log(`   ${fail} ${tsResult.count} error(s) — fix before next task`);
  }

  console.log('\n' + sep() + '\n' + c(C.bold, '⚙️  BUILD:'));
  if (buildResult === null)        console.log(`   ${skip} skipped`);
  else if (buildResult === true)   console.log(`   ${ok} PASSED`);
  else                             console.log(`   ${fail} FAILED`);

  const alive = healthCheck();
  console.log('\n' + c(C.bold, '🌐 LOCAL:'));
  console.log(`   ${alive ? ok : skip} http://localhost:${PORT}${alive ? '' : '  (run pnpm dev)'}`);

  if (bundleInfo) {
    console.log('\n' + c(C.bold, '📦 BUNDLE:'));
    console.log(c(C.green, `   ✔ ${bundleInfo.path}`));
    console.log(c(C.dim,   `   ${bundleInfo.kb} KB`));
  }

  console.log('\\n' + sep('━'));
  if (buildResult === true) {
    console.log(c(C.bold + C.green, '   ✅ READY FOR NEXT TASK'));
  } else if (buildResult === false) {
    console.log(c(C.bold + C.red,   '   ⚠️  BUILD FAILED'));
  } else {
    console.log(c(C.bold + C.yellow,'   ○  BUILD SKIPPED — run pnpm build when ready'));
  }
  console.log(sep('━') + '\n');
}

// ─── Verification checkpoints ─────────────────────────────────
function printVerification(taskName) {
  const vPath = path.join(ROOT, 'verification.json');
  if (!fs.existsSync(vPath)) return;

  let verData;
  try { verData = JSON.parse(fs.readFileSync(vPath, 'utf-8')); } catch { return; }

  console.log('\\n' + sep('━'));
  console.log(c(C.bold, `🌐 POST-DEPLOY CHECKPOINTS — ${verData.title || taskName.toUpperCase()}`));
  console.log(sep('━'));

  (verData.checks || []).forEach((check, i) => {
    console.log(c(C.bold, `\n[${i + 1}] ${check.name}`));
    if (check.file) console.log(c(C.dim,  `    From: ${check.file}`));
    const isCurl = (check.url || '').startsWith('curl');
    console.log(isCurl
      ? c(C.cyan, `    CMD:  ${check.url}`)
      : c(C.blue, `    URL:  ${check.url}`));
    console.log(c(C.green, `    ✔     ${check.what}`));
  });

  console.log('\\n' + sep('━'));
  console.log(c(C.bold, '   ✅ VALIDATE THESE BEFORE NEXT TASK'));
  console.log(sep('━') + '\n');
}


// ─── Git Commit ─────────────────────────────────────────────────
// Auto-generates commit message from actually changed files
async function runGitCommit(taskName, report) {
  const { spawnSync: sp, execSync: ex } = require('child_process');

  console.log('\n' + sep('━'));
  console.log(c(C.bold, '📝 GIT — Commit & Push'));
  console.log(sep('━'));

  // ── Check changes ──────────────────────────────────────────────
  let hasChanges = false;
  let statusLines = [];
  try {
    const st = ex('git status --porcelain', { cwd: ROOT, encoding: 'utf-8', stdio: 'pipe' }).trim();
    hasChanges = st.length > 0;
    statusLines = st.split('\n').filter(Boolean);
  } catch {}

  if (!hasChanges) {
    console.log(c(C.dim, '\n   Nothing to commit — working tree clean.\n'));
    return;
  }

  // ── Detect current branch ──────────────────────────────────────
  let currentBranch = '';
  try {
    currentBranch = ex('git rev-parse --abbrev-ref HEAD', { cwd: ROOT, encoding: 'utf-8', stdio: 'pipe' }).trim();
  } catch {
    console.log(c(C.red, '\n❌ Cannot detect current branch — git error\n'));
    return;
  }

  // ── Build sprint-scoped file list (NEVER `git add .`) ──────────
  // Only stage files declared by the sprint manifest (report.created + report.modified).
  // Anything else in working tree (.solar-backups, .solar-bundles, sprint/, tmp files,
  // unrelated edits) is deliberately ignored.
  const sprintFiles = [...new Set([...report.created, ...report.modified])];

  // Show what changed and what WILL be staged vs what will NOT
  console.log(c(C.dim, '\n   Working tree status (git status --porcelain):'));
  statusLines.forEach(l => console.log(c(C.dim, '   ' + l)));

  console.log(c(C.bold, '\n   Will stage ONLY sprint files (' + sprintFiles.length + '):'));
  sprintFiles.forEach(f => console.log(c(C.green, '   + ' + f)));

  // Detect non-sprint changes that would be left behind
  const sprintSet = new Set(sprintFiles);
  const leftBehind = statusLines
    .map(l => l.slice(3))           // strip "?? " or " M " etc
    .filter(p => p && !sprintSet.has(p));
  if (leftBehind.length > 0) {
    console.log(c(C.yellow, '\n   ⚠ Not staging (left in working tree):'));
    leftBehind.forEach(p => console.log(c(C.yellow, '   - ' + p)));
    console.log(c(C.dim, '   (these are NOT included in this commit — handle separately)'));
  }

  // ── Auto-generate commit message ───────────────────────────────
  const parts = [];
  if (report.created.length > 0)  parts.push('+' + report.created.length + ' new');
  if (report.modified.length > 0) parts.push('~' + report.modified.length + ' patched');

  const keyFiles = sprintFiles
    .map(f => path.basename(f, path.extname(f)))
    .slice(0, 3).join(', ');

  const autoMsg = 'task' + taskName + ': ' +
    (parts.length > 0 ? parts.join(', ') : 'deploy') +
    (keyFiles ? ' — ' + keyFiles : '') +
    ' [SDP v3]';

  console.log(c(C.bold, '\n   Auto commit message:'));
  console.log(c(C.cyan, '   "' + autoMsg + '"'));

  // ═══════════════════════════════════════════════════════════════
  // PHASE 1 — Commit decision
  // ═══════════════════════════════════════════════════════════════
  const commitAns = (await ask(
    c(C.bold, '\n   [Phase 1] Commit changes? [Y] yes  [E] edit message  [N] no  > ')
  )).toLowerCase().trim();

  if (commitAns === 'n' || commitAns === '') {
    console.log(c(C.dim, '\n   Commit skipped. Manual command if you want it later:'));
    console.log(c(C.cyan, '   git add ' + sprintFiles.map(f => JSON.stringify(f)).join(' ')));
    console.log(c(C.cyan, '   git commit -m "' + autoMsg + '"\n'));
    return;
  }

  let commitMsg = autoMsg;
  if (commitAns === 'e') {
    const edited = (await ask(c(C.bold, '   New message: '))).trim();
    if (edited) commitMsg = edited;
    console.log(c(C.dim, '   Message: "' + commitMsg + '"'));
  } else if (commitAns !== 'y') {
    console.log(c(C.yellow, '\n   Unrecognized answer — treating as N (skip).\n'));
    return;
  }

  // ── Stage ONLY sprint files (explicit paths, never `git add .`) ─
  const addArgs = ['add', '--', ...sprintFiles];
  const ar = sp('git', addArgs, { cwd: ROOT, stdio: 'inherit' });
  if (ar.status !== 0) {
    console.log(c(C.red, '\n❌ git add failed for one or more sprint files\n'));
    return;
  }
  console.log(c(C.green, '\n   ✅ Staged ' + sprintFiles.length + ' sprint file(s) — nothing else'));

  // ── git commit ─────────────────────────────────────────────────
  const cr = sp('git', ['commit', '-m', commitMsg], { cwd: ROOT, stdio: 'inherit' });
  if (cr.status !== 0) {
    console.log(c(C.red, '\n❌ git commit failed\n'));
    return;
  }
  console.log(c(C.green, '\n   ✅ Committed locally'));

  // ═══════════════════════════════════════════════════════════════
  // PHASE 2 — Push decision (separate from commit)
  // ═══════════════════════════════════════════════════════════════
  console.log(c(C.dim, '\n   Detected branch:  ') + c(C.bold, currentBranch));
  console.log(c(C.dim, '   Push target:      ') + c(C.bold, 'origin/' + currentBranch));

  // Warn if on main / master
  const isProtected = (currentBranch === 'main' || currentBranch === 'master');
  if (isProtected) {
    console.log(c(C.red, '\n   ⚠️  WARNING: you are on protected branch "' + currentBranch + '"'));
    console.log(c(C.red, '   ⚠️  Pushing directly to ' + currentBranch + ' bypasses PR + audit.'));
    console.log(c(C.red, '   ⚠️  Type the branch name EXACTLY to confirm, or anything else to cancel.'));
    const confirm = (await ask(
      c(C.bold, '   Confirm push to "' + currentBranch + '"? Type branch name: ')
    )).trim();
    if (confirm !== currentBranch) {
      console.log(c(C.yellow, '\n   Push cancelled. Commit remains LOCAL on ' + currentBranch + '.'));
      console.log(c(C.dim, '   Run later if needed:'));
      console.log(c(C.cyan, '   git push origin ' + currentBranch + '\n'));
      return;
    }
  }

  const pushAns = (await ask(
    c(C.bold, '\n   [Phase 2] Push to origin/' + currentBranch + '? [Y] yes  [O] override branch  [N] no  > ')
  )).toLowerCase().trim();

  if (pushAns === 'n' || pushAns === '') {
    console.log(c(C.dim, '\n   Push skipped. Commit is LOCAL on ' + currentBranch + '.'));
    console.log(c(C.dim, '   When ready:'));
    console.log(c(C.cyan, '   git push origin ' + currentBranch + '\n'));
    return;
  }

  // ═══════════════════════════════════════════════════════════════
  // PHASE 3 — Override branch (optional)
  // ═══════════════════════════════════════════════════════════════
  let pushBranch = currentBranch;
  if (pushAns === 'o') {
    const override = (await ask(
      c(C.bold, '   Target branch name (will create on remote if new): ')
    )).trim();
    if (!override) {
      console.log(c(C.yellow, '\n   No branch entered — push cancelled.'));
      console.log(c(C.cyan, '   git push origin ' + currentBranch + '\n'));
      return;
    }
    pushBranch = override;
    console.log(c(C.dim, '   Override target: ') + c(C.bold, 'origin/' + pushBranch));
  } else if (pushAns !== 'y') {
    console.log(c(C.yellow, '\n   Unrecognized answer — treating as N (skip push).'));
    console.log(c(C.cyan, '   git push origin ' + currentBranch + '\n'));
    return;
  }

  // ── git push ───────────────────────────────────────────────────
  // If pushing local branch X to remote branch Y, use X:Y syntax.
  // Otherwise simple push to same-named remote branch.
  const pushRefspec = (pushBranch === currentBranch)
    ? currentBranch
    : currentBranch + ':' + pushBranch;

  console.log(c(C.dim, '\n   Pushing to origin/' + pushBranch + '...'));
  const pr = sp('git', ['push', 'origin', pushRefspec], { cwd: ROOT, stdio: 'inherit' });
  if (pr.status !== 0) {
    console.log(c(C.red, '\n❌ git push failed — check remote/branch/permissions\n'));
    console.log(c(C.dim, '   Try manually: ') + c(C.cyan, 'git push origin ' + pushRefspec + '\n'));
    return;
  }

  console.log(c(C.green, '\n✅ Committed & pushed → origin/' + pushBranch));
  console.log(c(C.dim,   '   "' + commitMsg + '"\n'));

  // Hint for next step
  if (pushBranch !== 'main' && pushBranch !== 'master') {
    console.log(c(C.dim, '   Next step: open a PR from "' + pushBranch + '" → main'));
    console.log(c(C.cyan, '   gh pr create --base main --head ' + pushBranch + '\n'));
  }
}
// ═══════════════════════════════════════════════════════════════
// MAIN
// ═══════════════════════════════════════════════════════════════
async function main() {

  // ── Special modes ────────────────────────────────────────────
  if (HISTORY) {
    showHistory();
    closeRL();
    return;
  }

  if (ROLLBACK) {
    if (!ARCHIVE) {
      const av = fs.existsSync(BACKUP_DIR) ? fs.readdirSync(BACKUP_DIR).join(', ') : 'none';
      console.log(`Usage: node solar-apply.js <taskName> --rollback\nAvailable: ${av}`);
    } else {
      doRollback(ARCHIVE);
    }
    closeRL();
    return;
  }

  if (!ARCHIVE || !fs.existsSync(ARCHIVE)) {
    console.log([
      c(C.bold, '\n🚀 Solar Dev Pipeline v3\n'),
      'Usage:',
      '  node solar-apply.js task59_clean.tar.gz',
      '  node solar-apply.js task59_clean.tar.gz --auto',
      '  node solar-apply.js task59_clean.tar.gz --dry',
      '  node solar-apply.js task59_clean.tar.gz --no-build',
      '  node solar-apply.js task59_clean.tar.gz --no-bundle',
      '  node solar-apply.js task59             --rollback',
      '  node solar-apply.js                    --history',
      '',
    ].join('\n'));
    closeRL();
    process.exit(1);
  }

  const taskName = path.basename(ARCHIVE, '.tar.gz')
    .replace(/_clean$/, '').replace(/_v\d+$/, '');

  // ── Header ───────────────────────────────────────────────────
  console.log(c(C.bold, '\n🚀 Solar Dev Pipeline v3'));
  console.log(sep('═'));
  console.log(`   Task:    ${c(C.bold, taskName)}`);
  console.log(`   Archive: ${ARCHIVE}`);
  if (DRY_RUN) console.log(c(C.yellow, '   Mode:    DRY RUN'));
  if (AUTO)    console.log(c(C.yellow, '   Mode:    AUTO'));
  console.log(sep('═'));

  // ── Step 1: Pre-Deploy Audit ──────────────────────────────────
  const tmpDir = extract(ARCHIVE);
  const files  = collectFiles(tmpDir);

  const auditNew   = [];
  const auditPatch = [];
  const auditSkip  = [];

  for (const f of files) {
    const dest   = path.join(ROOT, f);
    const exists = fs.existsSync(dest);
    const newTxt = fs.readFileSync(path.join(tmpDir, f), 'utf-8');
    const same   = exists && fs.readFileSync(dest, 'utf-8') === newTxt;
    if (!exists)   auditNew.push(f);
    else if (same) auditSkip.push(f);
    else           auditPatch.push(f);
  }

  console.log('\\n' + sep('━'));
  console.log(c(C.bold, '🔍 PRE-DEPLOY AUDIT'));
  console.log(sep('━'));

  if (auditNew.length > 0) {
    console.log(c(C.bold, `\n📁 NEW FILES (${auditNew.length}) — will be created:`));
    auditNew.forEach(f => console.log(c(C.green,  `   + ${f}`)));
  }
  if (auditPatch.length > 0) {
    console.log(c(C.bold, `\n🔧 PATCH FILES (${auditPatch.length}) — will be modified:`));
    auditPatch.forEach(f => console.log(c(C.yellow, `   ~ ${f}`)));
    console.log(c(C.dim,  `\n   Backups → .solar-backups/${taskName}/`));
  }
  if (auditSkip.length > 0) {
    console.log(c(C.bold, `\n⏭  IDENTICAL (${auditSkip.length}) — will be skipped:`));
    auditSkip.forEach(f => console.log(c(C.dim, `   = ${f}`)));
  }

  console.log('\\n' + sep('━'));
  console.log(c(C.bold, `📊 Total: ${c(C.green, auditNew.length + ' new')}  ${c(C.yellow, auditPatch.length + ' patch')}  ${c(C.dim, auditSkip.length + ' skip')}`));
  console.log(sep('━'));

  if (!AUTO && !DRY_RUN) {
    const go = (await ask(c(C.bold, '\n🚀 Ready to deploy? [Y] go  [Q] quit  > '))).toLowerCase().trim();
    if (go === 'q' || go === 'n') {
      fs.rmSync(tmpDir, { recursive: true, force: true });
      console.log(c(C.dim, '\nDeploy cancelled.\n'));
      closeRL();
      return;
    }
  }

  console.log(c(C.bold, '\n▶ Starting deploy...\n'));

  // ── Step 2: Controlled Apply ──────────────────────────────────
  const report   = { created: [], modified: [], dirs: [], diffSummary: [], skipped: 0 };
  const seenDirs = new Set();

  for (let i = 0; i < files.length; i++) {
    const rel    = files[i];
    const src    = path.join(tmpDir, rel);
    const dest   = path.join(ROOT, rel);
    const newTxt = fs.readFileSync(src, 'utf-8');
    const exists = fs.existsSync(dest);
    const oldTxt = exists ? fs.readFileSync(dest, 'utf-8') : '';
    const same   = exists && oldTxt === newTxt;

    const dir = path.dirname(rel);
    if (dir !== '.' && !fs.existsSync(path.join(ROOT, dir)) && !seenDirs.has(dir)) {
      seenDirs.add(dir);
      report.dirs.push(dir);
    }

    const badge = !exists ? c(C.green, '[ NEW   ]') : same ? c(C.dim, '[  ───  ]') : c(C.yellow, '[ PATCH ]');
    process.stdout.write(`\n[${i + 1}/${files.length}] ${badge} ${c(C.bold, rel)}\n`);

    if (same) { console.log(c(C.dim, '   identical')); report.skipped++; continue; }

    if (exists) {
      showColorDiff(oldTxt, newTxt);
      const { added, removed } = countDiffLines(oldTxt, newTxt);
      console.log(c(C.dim, `   lines: ${c(C.green, '+' + added)} ${c(C.red, '-' + removed)}`));
    } else {
      newTxt.split('\n').slice(0, 5).forEach(l => console.log(c(C.dim, '   ' + l)));
      if (newTxt.split('\n').length > 5) console.log(c(C.dim, '   ...'));
    }

    if (DRY_RUN) { console.log(c(C.yellow, '   👁 dry')); continue; }

    let ans = 'y';
    if (!AUTO) {
      ans = (await ask(c(C.bold, '   [Y] apply  [S] skip  [D] diff  [Q] quit  > '))).toLowerCase().trim() || 'y';
      if (ans === 'd') {
        exists ? showColorDiff(oldTxt, newTxt) : console.log(c(C.green, '   (new file)'));
        ans = (await ask(c(C.bold, '   [Y] apply  [S] skip  > '))).toLowerCase().trim() || 'y';
      }
      if (ans === 'q') {
        fs.rmSync(tmpDir, { recursive: true, force: true });
        closeRL();
        process.exit(0);
      }
    }

    if (ans !== 's') {
      backup(rel, taskName);
      fs.mkdirSync(path.dirname(dest), { recursive: true });
      fs.writeFileSync(dest, newTxt);
      console.log(c(C.green, '   ✅ applied'));
      if (!exists) {
        report.created.push(rel);
      } else {
        report.modified.push(rel);
        const { added, removed } = countDiffLines(oldTxt, newTxt);
        report.diffSummary.push({ file: rel, added, removed });
      }
    } else {
      console.log(c(C.dim, '   ⏭ skipped'));
      report.skipped++;
    }
  }

  fs.rmSync(tmpDir, { recursive: true, force: true });

  if (DRY_RUN) {
    console.log(c(C.yellow, '\n👁 Dry run complete — nothing written.\n'));
    closeRL();
    return;
  }

  // ── Quick deploy summary ──────────────────────────────────────
  const totalApplied = report.created.length + report.modified.length;
  console.log('\\n' + sep('━'));
  console.log(c(C.bold, '📊 DEPLOY SUMMARY:'));
  console.log(`   📁 New:     ${c(C.green,  String(report.created.length))}`);
  console.log(`   🔧 Patched: ${c(C.yellow, String(report.modified.length))}`);
  console.log(`   ⏭  Skipped: ${c(C.dim,    String(report.skipped))}`);
  if (report.modified.length > 0) {
    console.log(c(C.dim, `\n   Backup → .solar-backups/${taskName}/`));
    console.log(c(C.dim, `   Rollback: node solar-apply.js ${taskName} --rollback`));
  }
  console.log(sep('━'));

  // ── Step 3: Dependency Check ──────────────────────────────────
  if (!NO_BUILD) {
    await ensureNodeModules();
  }

  // ── Step 4 + 5: TypeScript Full Scan + Decision ───────────────
  let tsResult   = null;
  let buildResult = null;
  let doRunBuild = false;

  if (!NO_BUILD) {
    tsResult = runTypeCheck();

    if (tsResult.passed) {
      // No TS errors — ask about build
      const ans = (await ask(c(C.bold, '⚡ Run pnpm build? [Y] yes  [N] skip  > '))).toLowerCase().trim();
      doRunBuild = (ans === '' || ans === 'y');
    } else {
      // TS errors found — show options
      console.log(c(C.bold, '\n⚡ Options:'));
      console.log(`   [Y] Continue with build anyway (errors may cause failure)`);
      console.log(`   [N] Skip build (fix TS errors first, run pnpm build manually)`);
      console.log(`   [Q] Quit\n`);
      const ans = (await ask(c(C.bold, '   Choice > '))).toLowerCase().trim();
      if (ans === 'q') {
        closeRL();
        process.exit(0);
      }
      doRunBuild = (ans === '' || ans === 'y');
      if (!doRunBuild) {
        console.log(c(C.dim, '\n   Build skipped. Fix TS errors, then run: pnpm build\n'));
      }
    }

    // ── Step 6: Build ─────────────────────────────────────────
    if (doRunBuild) {
      buildResult = runBuildSync(taskName);
    }
  }

  // ── Step 8: Bundle ───────────────────────────────────────────
  let bundleInfo = null;
  if (!NO_BUNDLE && buildResult === true) {
    console.log(c(C.bold, '\n📦 Creating clean bundle...'));
    bundleInfo = createBundle(taskName, report, true);
    console.log(c(C.green, `   ✔ ${bundleInfo.path} (${bundleInfo.kb} KB)\n`));
  }

  // ── Save History ──────────────────────────────────────────────
  saveHistory(taskName, {
    files_created:  report.created.length,
    files_modified: report.modified.length,
    files_skipped:  report.skipped,
    dirs_created:   report.dirs.length,
    ts_errors:      tsResult ? tsResult.count : null,
    build:          buildResult === true ? 'passed' : buildResult === false ? 'failed' : 'skipped',
    bundle:         bundleInfo?.path || null,
    created:        report.created,
    modified:       report.modified,
  });

  // ── Step 7: Deploy Report ─────────────────────────────────────
  printReport(taskName, report, buildResult, tsResult, bundleInfo);

  // ── Verification Checkpoints ──────────────────────────────────
  if (buildResult === true) {
    printVerification(taskName);
  }

  // ── Git Commit (Solar Rule #1) ─────────────────────────────────
  if (buildResult === true) {
    await runGitCommit(taskName, report);
  }

  // ── CLOSE readline ONCE here at the very end ──────────────────
  closeRL();
}

main().catch(e => {
  console.error(e);
  closeRL();
  process.exit(1);
});


