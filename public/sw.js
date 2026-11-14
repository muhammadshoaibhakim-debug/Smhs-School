// Fast start: the app pages always come fresh from the network (if the network is slow, the saved copy is used after 3.5 s).
// The big library and the icons come from the saved copy at once and are refreshed quietly in the background.
// Supabase calls (other origin) are never touched, so data is never served stale.
const C='smhs-school-v1';
self.addEventListener('install',()=>self.skipWaiting());
self.addEventListener('activate',e=>e.waitUntil(caches.keys().then(k=>Promise.all(k.filter(x=>x!==C).map(x=>caches.delete(x)))).then(()=>self.clients.claim())));
const put=(r,res)=>{if(res&&res.ok){const cp=res.clone();caches.open(C).then(c=>c.put(r,cp))}return res};
self.addEventListener('fetch',e=>{const r=e.request,u=new URL(r.url);
  if(r.method!=='GET'||u.origin!==location.origin)return;
  if(/\/(vendor|icons)\//.test(u.pathname)){
    e.respondWith(caches.match(r).then(m=>{const net=fetch(r).then(res=>put(r,res)).catch(()=>m);return m||net}));return}
  e.respondWith(new Promise(resolve=>{let done=false;
    const fall=()=>caches.match(r).then(m=>{if(m&&!done){done=true;resolve(m)}});
    const t=setTimeout(fall,3500);
    fetch(r).then(res=>{clearTimeout(t);if(!done){done=true;resolve(put(r,res))}else put(r,res)})
      .catch(()=>{clearTimeout(t);caches.match(r).then(m=>{if(!done){done=true;resolve(m||Response.error())}})})}))});

// ---- phone notifications (absent / fee reminder / diary): shown even when the app is closed
self.addEventListener('push',e=>{
  let d={};try{d=e.data?e.data.json():{}}catch(_){d={body:e.data?e.data.text():''}}
  e.waitUntil(self.registration.showNotification(d.title||'Scholars Model High School',{body:d.body||'',tag:d.tag||undefined,icon:'icons/app-192.png',badge:'icons/logo-48.png',data:{url:d.url||'./'}}))});
self.addEventListener('notificationclick',e=>{
  e.notification.close();const u=new URL((e.notification.data&&e.notification.data.url)||'./',self.registration.scope).href;
  e.waitUntil(self.clients.matchAll({type:'window',includeUncontrolled:true}).then(l=>{for(const c of l){if('focus'in c)return c.focus()}return self.clients.openWindow(u)}))});
