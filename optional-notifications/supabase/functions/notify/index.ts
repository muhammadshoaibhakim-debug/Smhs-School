// Supabase Edge Function "notify": sends phone notifications to parents.
//  1) ABSENT: when the teacher submits attendance and a child is marked Absent.
//  2) FEES: every day from FEE_HOUR (Pakistan time) on, for every child whose fee of THIS month is not paid yet. Starts on the 1st, stops once paid.
//  3) DIARY: when a diary entry is published.
// Called every 2 minutes by the database clock (header x-cron-secret), and by the app's "Send me a test" button (the user's own login).
// Secrets to set in the function: CRON_SECRET, VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT (optional), FEE_HOUR (optional, default 9).
import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

// ---PURE-START (no database, no network: tested separately)
function pkt(ms) {
  const d = new Date(ms + 5 * 3600 * 1000); // Pakistan = UTC+5, no daylight saving
  return { day: d.toISOString().slice(0, 10), hour: d.getUTCHours() };
}
function addDays(day, n) {
  const d = new Date(day + "T00:00:00Z"); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10);
}
const MONTHS = ["January","February","March","April","May","June","July","August","September","October","November","December"];
function monthName(ym) { return MONTHS[Number(ym.slice(5, 7)) - 1] + " " + ym.slice(0, 4); }
// links: [{parent_id, student_id}], activeParents: Set of parent ids that may receive
function parentsByStudent(links, activeParents) {
  const m = {};
  for (const l of links) { if (!activeParents.has(l.parent_id)) continue; (m[l.student_id] = m[l.student_id] || []).push(l.parent_id); }
  return m;
}
function planFees({ students, paidIds, links, activeParents, day }) {
  const paid = new Set(paidIds), pm = parentsByStudent(links, activeParents), by = {};
  for (const s of students) {
    if (paid.has(s.id) || !(s.monthly_fee > 0) || s.admission_date > day) continue;
    for (const p of pm[s.id] || []) (by[p] = by[p] || []).push({ name: s.name, fee: s.monthly_fee });
  }
  return Object.keys(by).map((p) => ({ parent: p, kids: by[p] }));
}
function planAbsent({ rows, finalSet, links, activeParents }) {
  const pm = parentsByStudent(links, activeParents), out = [];
  for (const r of rows) {
    const st = r.students; if (!st || st.status !== "Active") continue;
    if (!finalSet.has(st.class_id + "|" + r.day)) continue; // only after the teacher submitted the class
    for (const p of pm[r.student_id] || []) out.push({ parent: p, student: r.student_id, name: st.name, day: r.day });
  }
  return out;
}
// diary: new (not yet announced) published rows [{id,class_id,subject}], kidsByClass: {classId:[studentId]}
function planDiary({ diary, kidsByClass, links, activeParents }) {
  const pm = parentsByStudent(links, activeParents), byClass = {};
  for (const d of diary) (byClass[d.class_id] = byClass[d.class_id] || []).push(d.subject);
  const out = [];
  for (const c in byClass) {
    const ps = new Set();
    for (const sid of kidsByClass[c] || []) for (const p of pm[sid] || []) ps.add(p);
    for (const p of ps) out.push({ parent: p, classId: c, subjects: [...new Set(byClass[c])] });
  }
  return out;
}
// ---PURE-END

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-cron-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (o, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...CORS, "Content-Type": "application/json" } });

const admin = createClient(Deno.env.get("SUPABASE_URL"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"), { auth: { persistSession: false } });
const CRON = Deno.env.get("CRON_SECRET") || "";
const FEE_HOUR = Number(Deno.env.get("FEE_HOUR") || "9");
let vapidOk = false;
function initVapid() {
  if (vapidOk) return true;
  const pub = Deno.env.get("VAPID_PUBLIC_KEY"), priv = Deno.env.get("VAPID_PRIVATE_KEY");
  if (!pub || !priv) return false;
  webpush.setVapidDetails(Deno.env.get("VAPID_SUBJECT") || "mailto:admin@example.com", pub, priv);
  vapidOk = true; return true;
}

async function fetchAll(build) { // PostgREST returns at most 1000 rows per request
  const out = [];
  for (let from = 0; ; from += 1000) {
    const { data, error } = await build().range(from, from + 999);
    if (error) throw new Error(error.message);
    out.push(...data); if (data.length < 1000) break;
  }
  return out;
}
async function claim(kind, key, day) { // true only the first time: this is what stops double notifications
  const { error } = await admin.from("notif_log").insert({ kind, key, day });
  if (!error) return true;
  if (error.code === "23505") return false;
  throw new Error("notif_log: " + error.message);
}
async function sendToUsers(userIds, payload) {
  if (!userIds.length) return 0;
  const subs = await fetchAll(() => admin.from("push_subs").select("id,endpoint,p256dh,auth_key,user_id").in("user_id", userIds).order("id"));
  let sent = 0;
  for (const s of subs) {
    try {
      await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth_key } }, JSON.stringify(payload), { TTL: 43200, urgency: "high" });
      sent++;
    } catch (e) {
      if (e && (e.statusCode === 404 || e.statusCode === 410)) await admin.from("push_subs").delete().eq("id", s.id); // phone removed the app
      else console.error("push failed", e && (e.statusCode || e.message));
    }
  }
  return sent;
}
async function activeParentSet(ids) {
  const set = new Set(); const u = [...new Set(ids)];
  for (let i = 0; i < u.length; i += 200) {
    const { data, error } = await admin.from("profiles").select("id").eq("role", "parent").eq("active", true).in("id", u.slice(i, i + 200));
    if (error) throw new Error(error.message);
    data.forEach((r) => set.add(r.id));
  }
  return set;
}
async function linksFor(studentIds) {
  const out = []; const u = [...new Set(studentIds)];
  for (let i = 0; i < u.length; i += 200) {
    const { data, error } = await admin.from("parent_students").select("parent_id,student_id").in("student_id", u.slice(i, i + 200));
    if (error) throw new Error(error.message);
    out.push(...data);
  }
  return out;
}

async function runAll() {
  const now = pkt(Date.now()), day = now.day, yday = addDays(day, -1), res = { absent: 0, fees: 0, diary: 0 };
  // ---- 1) absent
  const abs = await fetchAll(() => admin.from("attendance").select("student_id,day,students(name,class_id,status)").eq("status", "Absent").gte("day", yday).order("day"));
  if (abs.length) {
    const fin = await fetchAll(() => admin.from("attendance_final").select("class_id,day").gte("day", yday).order("day"));
    const finalSet = new Set(fin.map((f) => f.class_id + "|" + f.day));
    const links = await linksFor(abs.map((r) => r.student_id));
    const ap = await activeParentSet(links.map((l) => l.parent_id));
    for (const a of planAbsent({ rows: abs, finalSet, links, activeParents: ap })) {
      if (!(await claim("absent", a.parent + "|" + a.student, a.day))) continue;
      res.absent += await sendToUsers([a.parent], { title: "Absent: " + a.name, body: a.name + " was marked ABSENT on " + a.day + ".", tag: "absent-" + a.student + "-" + a.day, url: "./" });
    }
  }
  // ---- 2) fees (from FEE_HOUR, every day, until paid)
  if (now.hour >= FEE_HOUR) {
    const month = day.slice(0, 7);
    const students = await fetchAll(() => admin.from("students").select("id,name,monthly_fee,admission_date").eq("status", "Active").order("id"));
    const paid = await fetchAll(() => admin.from("fees").select("student_id").eq("month", month).eq("kind", "payment").eq("reversed", false).order("id"));
    const paidIds = paid.map((p) => p.student_id), ps = new Set(paidIds);
    const due = students.filter((s) => !ps.has(s.id) && s.monthly_fee > 0);
    if (due.length) {
      const links = await linksFor(due.map((s) => s.id));
      const ap = await activeParentSet(links.map((l) => l.parent_id));
      for (const f of planFees({ students: due, paidIds, links, activeParents: ap, day })) {
        if (!(await claim("fee", f.parent, day))) continue;
        const list = f.kids.map((k) => k.name + " (Rs " + k.fee + ")").join(", ");
        res.fees += await sendToUsers([f.parent], { title: "Fee reminder: " + monthName(month), body: list + " - fee not paid yet. Please pay at the school office.", tag: "fee-" + month, url: "./" });
      }
    }
  }
  // ---- 3) diary
  const dr = await fetchAll(() => admin.from("diary").select("id,class_id,day,subject").eq("published", true).gte("day", yday).order("id"));
  const fresh = [];
  for (const d of dr) if (await claim("diary", d.id, d.day)) fresh.push(d);
  if (fresh.length) {
    const classes = [...new Set(fresh.map((d) => d.class_id))];
    const { data: kids, error } = await admin.from("students").select("id,class_id").eq("status", "Active").in("class_id", classes);
    if (error) throw new Error(error.message);
    const kidsByClass = {}; kids.forEach((k) => (kidsByClass[k.class_id] = kidsByClass[k.class_id] || []).push(k.id));
    const links = await linksFor(kids.map((k) => k.id));
    const ap = await activeParentSet(links.map((l) => l.parent_id));
    const { data: cl } = await admin.from("classes").select("id,name").in("id", classes);
    const cname = {}; (cl || []).forEach((c) => (cname[c.id] = c.name));
    for (const d of planDiary({ diary: fresh, kidsByClass, links, activeParents: ap })) {
      res.diary += await sendToUsers([d.parent], { title: "Diary: " + (cname[d.classId] || "Class"), body: "New diary / homework: " + d.subjects.join(", ") + ".", tag: "diary-" + d.classId + "-" + day, url: "./" });
    }
  }
  // tidy: forget old log lines
  await admin.from("notif_log").delete().lt("day", addDays(day, -60));
  return res;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
  try {
    if (!initVapid()) return json({ error: "VAPID keys are not set in the function secrets" }, 500);
    const body = await req.json().catch(() => ({}));
    if (body && body.action === "test") { // the signed-in user tests his own phone
      const token = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
      const { data, error } = await admin.auth.getUser(token);
      if (error || !data || !data.user) return json({ error: "Please sign in again" }, 401);
      const sent = await sendToUsers([data.user.id], { title: "Test notification", body: "Notifications are working on this phone.", tag: "test", url: "./" });
      return json({ sent });
    }
    if (!CRON || req.headers.get("x-cron-secret") !== CRON) return json({ error: "Not allowed" }, 401);
    return json(await runAll());
  } catch (e) {
    console.error(e); return json({ error: String((e && e.message) || e) }, 500);
  }
});
