// Maintenance from Slack: the /maintenance command of the "t4a server" Slack app.
// Serves banner.json for the apps and the "back soon" page for sites in down mode.
// Lives in /srv/maintenance on t4a (servers/t4a/README.md). Node, no dependencies.
import http from 'node:http';
import crypto from 'node:crypto';
import fs from 'node:fs';

const { SLACK_SIGNING_SECRET, ALLOWED_USERS = '' } = process.env;
const STATE = process.env.STATE_FILE || '/data/state.json';
const TRAEFIK = process.env.TRAEFIK_FILE || '/traefik/maintenance.yml';   // bind-mounted /srv/edge/dynamic/maintenance.yml
const TZ = 'Europe/Ljubljana';
const BYPASS_PATH = '/__maintenance/bypass';
const allowed = ALLOWED_USERS.split(',').map(s => s.trim()).filter(Boolean);
const page = fs.readFileSync(new URL('./down.html', import.meta.url), 'utf8');

// { announce: {startsAt, endsAt, message} | null, down: {hosts, message, key, since} | null }
let state = { announce: null, down: null };
try { state = JSON.parse(fs.readFileSync(STATE, 'utf8')); } catch {}

function save() {
  fs.writeFileSync(STATE + '.tmp', JSON.stringify(state, null, 2));
  fs.renameSync(STATE + '.tmp', STATE);
  writeTraefik();
}

// Down mode is one high-priority router in Traefik's file provider: the chosen hosts go to this
// service, except requests carrying the bypass cookie. Written in place, the file is a bind mount.
function writeTraefik() {
  const d = state.down;
  const yml = !d ? '# No site in down mode. Written by /srv/maintenance, do not edit.\n' : `# Written by /srv/maintenance while /maintenance down is on, do not edit.
http:
  routers:
    maintenance-down:
      rule: "(${d.hosts.map(h => `Host(\`${h}\`)`).join(' || ')}) && !HeaderRegexp(\`Cookie\`, \`t4a_bypass=${d.key}\`)"
      priority: 100000
      entryPoints: [websecure]
      service: maintenance@docker
      tls: {}
`;
  fs.writeFileSync(TRAEFIK, yml);
}

// --- time, in Ljubljana time ---

function tzOffsetMs(utcMs) {
  const p = Object.fromEntries(new Intl.DateTimeFormat('en-GB', {
    timeZone: TZ, hourCycle: 'h23', year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', second: '2-digit',
  }).formatToParts(utcMs).map(x => [x.type, x.value]));
  return Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute, p.second) - utcMs;
}

function localToUtc(y, mo, d, h, mi) {
  const guess = Date.UTC(y, mo - 1, d, h, mi);
  return guess - tzOffsetMs(guess - tzOffsetMs(guess));
}

function todayLocal(offsetDays = 0) {
  const s = new Intl.DateTimeFormat('en-CA', { timeZone: TZ }).format(Date.now() + offsetDays * 864e5);
  return s.split('-').map(Number);
}

const fmt = (ms, opts) => new Intl.DateTimeFormat('en-GB', { timeZone: TZ, ...opts }).format(ms);
const fmtDay = ms => fmt(ms, { weekday: 'short', day: 'numeric', month: 'short' });
const fmtTime = ms => fmt(ms, { hour: '2-digit', minute: '2-digit', hourCycle: 'h23' });

// "[today|tomorrow|YYYY-MM-DD] HH:MM <duration> message", duration like 30m, 2h, 1h30m
function parseAnnounce(words) {
  let date;
  if (words[0] === 'today') { date = todayLocal(0); words.shift(); }
  else if (words[0] === 'tomorrow') { date = todayLocal(1); words.shift(); }
  else if (/^\d{4}-\d{2}-\d{2}$/.test(words[0])) { date = words.shift().split('-').map(Number); }
  const t = /^(\d{1,2}):(\d{2})$/.exec(words.shift() || '');
  const dur = /^(?:(\d+)h)?(?:(\d+)m)?$/.exec(words.shift() || '');
  if (!t || !dur || !(dur[1] || dur[2])) return null;
  let start = localToUtc(...(date || todayLocal(0)), +t[1], +t[2]);
  if (!date && start < Date.now()) start = localToUtc(...todayLocal(1), +t[1], +t[2]);
  const end = start + ((+dur[1] || 0) * 60 + (+dur[2] || 0)) * 6e4;
  return { startsAt: new Date(start).toISOString(), endsAt: new Date(end).toISOString(), message: unquote(words.join(' ')) };
}

const unquote = s => s.trim().replace(/^["“”']+|["“”']+$/g, '').trim();

// --- what the apps show ---

function banner() {
  const now = Date.now(), a = state.announce, d = state.down;
  if (d) return { active: true, level: 'down', text: `Maintenance in progress: ${d.message}`, since: d.since };
  if (a && now < Date.parse(a.endsAt)) {
    const s = Date.parse(a.startsAt), e = Date.parse(a.endsAt);
    const text = now < s
      ? `Planned maintenance ${fmtDay(s)}, ${fmtTime(s)}–${fmtTime(e)}: ${a.message}`
      : `Maintenance in progress until ${fmtTime(e)}: ${a.message}`;
    return { active: true, level: now < s ? 'planned' : 'now', text, startsAt: a.startsAt, endsAt: a.endsAt };
  }
  return { active: false };
}

function statusText() {
  const b = banner(), d = state.down, lines = [];
  lines.push(b.active ? `Banner in every app: _${b.text}_` : 'No banner.');
  if (d) {
    lines.push(`Down page since ${fmtDay(Date.parse(d.since))} ${fmtTime(Date.parse(d.since))} for:`);
    for (const h of d.hosts) lines.push(`• ${h}, to see the real site: https://${h}${BYPASS_PATH}?key=${d.key}`);
  } else lines.push('No site in down mode.');
  return lines.join('\n');
}

const HELP = `*/maintenance* commands (times are Ljubljana time):
• \`/maintenance announce tomorrow 22:00 30m Moving the database\`: banner in every app from now until the window ends. Date: \`today\`, \`tomorrow\` or \`2026-11-02\`; without one, the next 22:00.
• \`/maintenance down jakamarinko.com api.time-4-action.com Moving servers\`: "back soon" page for those sites, banner in every app.
• \`/maintenance end\`: banner and down page off.
• \`/maintenance status\`: what is on, with links that get past the down page.`;

// --- Slack ---

function verifySlack(req, raw) {
  const ts = req.headers['x-slack-request-timestamp'], sig = req.headers['x-slack-signature'];
  if (!SLACK_SIGNING_SECRET || !ts || !sig || Math.abs(Date.now() / 1000 - ts) > 300) return false;
  const mine = 'v0=' + crypto.createHmac('sha256', SLACK_SIGNING_SECRET).update(`v0:${ts}:${raw}`).digest('hex');
  return mine.length === sig.length && crypto.timingSafeEqual(Buffer.from(mine), Buffer.from(sig));
}

function command(text, user) {
  const words = text.trim().split(/\s+/).filter(Boolean);
  const cmd = (words.shift() || 'help').toLowerCase();
  const say = text => ({ response_type: 'in_channel', text });
  const whisper = text => ({ response_type: 'ephemeral', text });

  if (cmd === 'status') return whisper(statusText());
  if (cmd === 'announce') {
    const a = parseAnnounce(words);
    if (!a || !a.message) return whisper('Could not read that.\n' + HELP);
    if (Date.parse(a.endsAt) <= Date.now()) return whisper('That window is already over.');
    state.announce = a; save();
    return say(`<@${user}> announced maintenance. Every app now shows: _${banner().text}_`);
  }
  if (cmd === 'down') {
    const hosts = [];
    while (words.length && /^[a-z0-9-]+(\.[a-z0-9-]+)+$/i.test(words[0])) hosts.push(words.shift().toLowerCase());
    if (!hosts.length) return whisper('Name at least one site, like `jakamarinko.com`.\n' + HELP);
    const message = unquote(words.join(' ')) || 'We are moving to a new server.';
    state.down = { hosts, message, key: crypto.randomBytes(12).toString('hex'), since: new Date().toISOString() };
    save();
    return say(`<@${user}> turned on the down page for ${hosts.join(', ')}: _${message}_\n` +
      'Sites still served from T-2 only get it once their DNS points at Hetzner. `/maintenance status` has links past the page.');
  }
  if (cmd === 'end') {
    const had = state.down || (state.announce && Date.now() < Date.parse(state.announce.endsAt));
    state = { announce: null, down: null }; save();
    return say(had ? `<@${user}> ended maintenance: banner and down page are off.` : 'Nothing was on.');
  }
  return whisper(HELP);
}

// --- HTTP ---

function send(res, code, body, headers = {}) {
  res.writeHead(code, headers);
  res.end(body);
}

const escape = s => s.replace(/[&<>"']/g, c => `&#${c.charCodeAt(0)};`);
const isOwnHost = host => host === 'maintenance.time-4-action.com' || host === 'localhost';

http.createServer((req, res) => {
  const url = new URL(req.url, 'http://x');
  const host = (req.headers.host || '').split(':')[0].toLowerCase();
  // Traefik's health check calls the container IP, so it comes before the host check.
  if (url.pathname === '/health') return send(res, 200, 'ok');

  // A site in down mode: every request lands here (Traefik router above).
  if (!isOwnHost(host)) {
    const d = state.down;
    if (d && url.pathname === BYPASS_PATH && url.searchParams.get('key') === d.key) {
      return send(res, 302, '', { Location: '/', 'Set-Cookie': `t4a_bypass=${d.key}; Path=/; Max-Age=86400; Secure; HttpOnly; SameSite=Lax` });
    }
    return send(res, 503, page.replace('{{message}}', () => escape(d ? d.message : 'We are working on the site.')), {
      'Content-Type': 'text/html; charset=utf-8', 'Retry-After': '600', 'Cache-Control': 'no-store',
    });
  }

  if (url.pathname === '/banner.json') {
    return send(res, 200, JSON.stringify(banner()), {
      'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*', 'Cache-Control': 'public, max-age=60',
    });
  }

  if (url.pathname === '/slack/command' && req.method === 'POST') {
    let raw = '';
    req.on('data', c => { raw += c; if (raw.length > 1e5) req.destroy(); });
    req.on('end', () => {
      if (!verifySlack(req, raw)) return send(res, 401, 'bad signature');
      const p = new URLSearchParams(raw);
      const user = p.get('user_id');
      const reply = allowed.includes(user)
        ? command(p.get('text') || '', user)
        : { response_type: 'ephemeral', text: `Not allowed for your Slack user (${user}). Ask to be added to ALLOWED_USERS in /srv/maintenance/.env.` };
      console.log(new Date().toISOString(), user, JSON.stringify(p.get('text')), allowed.includes(user) ? 'ok' : 'denied');
      send(res, 200, JSON.stringify(reply), { 'Content-Type': 'application/json' });
    });
    return;
  }
  send(res, 404, 'not found');
}).listen(3000, () => { writeTraefik(); console.log('listening on :3000'); });
