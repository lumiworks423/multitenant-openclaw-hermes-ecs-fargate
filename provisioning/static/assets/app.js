// OpenClaw Workshop — Vanilla JS SPA (no React build step needed)
const API = '/api';
let token = localStorage.getItem('token') || '';
let currentUser = null;

function $(sel) { return document.querySelector(sel); }
function api(method, path, body) {
  const opts = { method, headers: { 'Content-Type': 'application/json' } };
  if (token) opts.headers['Authorization'] = `Bearer ${token}`;
  if (body) opts.body = JSON.stringify(body);
  return fetch(`${API}${path}`, opts).then(async r => {
    const data = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(data.detail || `HTTP ${r.status}`);
    return data;
  });
}

// ── Render functions ──

function renderLogin() {
  $('#app').innerHTML = `
    <div class="card">
      <h2>Login</h2>
      <div id="error" class="error hidden"></div>
      <input id="username" placeholder="Username" autocomplete="username" />
      <input id="password" type="password" placeholder="Password" autocomplete="current-password" />
      <button id="loginBtn">Login</button>
      <div class="link-row"><a id="toRegister">Don't have an account? Register</a></div>
    </div>`;
  $('#loginBtn').onclick = doLogin;
  $('#toRegister').onclick = renderRegister;
  $('#password').onkeydown = e => { if (e.key === 'Enter') doLogin(); };
}

function renderRegister() {
  $('#app').innerHTML = `
    <div class="card">
      <h2>Register</h2>
      <div id="error" class="error hidden"></div>
      <input id="username" placeholder="Choose a username" autocomplete="username" />
      <input id="password" type="password" placeholder="Choose a password" autocomplete="new-password" />
      <button id="registerBtn">Register & Get Your Instance</button>
      <div class="link-row"><a id="toLogin">Already have an account? Login</a></div>
    </div>`;
  $('#registerBtn').onclick = doRegister;
  $('#toLogin').onclick = renderLogin;
  $('#password').onkeydown = e => { if (e.key === 'Enter') doRegister(); };
}

function renderDashboard() {
  const u = currentUser;
  const inst = u.instance;
  const isAdmin = u.role === 'admin';

  let instanceHtml = '';
  if (inst) {
    instanceHtml = `
      <div class="instance-card">
        <p class="status">● Instance Running</p>
        <p style="margin-top:12px"><strong>Slot:</strong> ${inst.slot_id}</p>

        <p style="margin-top:12px"><strong>🤖 OpenClaw (Control UI):</strong></p>
        <p><a href="${inst.access_url}" target="_blank">${inst.access_url}</a></p>

        <p style="margin-top:12px"><strong>🧠 Hermes (Open WebUI):</strong></p>
        <p><a href="${inst.openwebui_url}" target="_blank">${inst.openwebui_url}</a></p>

        <p style="margin-top:8px"><strong>Gateway Token (OpenClaw):</strong></p>
        <div class="token-box">${inst.gateway_token}</div>
        <p style="margin-top:16px;color:#888;font-size:0.85rem">
          <strong>OpenClaw:</strong> Open the Control UI link → chat with your AI agent. To connect Feishu: tell the agent "帮我连接飞书".<br>
          <strong>Hermes:</strong> Open the Open WebUI link → select hermes-agent from the model dropdown.
        </p>
      </div>`;
  } else {
    instanceHtml = `
      <button id="assignBtn">🚀 Get My AI Agent Instances</button>
      <div id="assignError" class="error hidden" style="margin-top:12px"></div>`;
  }

  let adminHtml = '';
  if (isAdmin) {
    adminHtml = `
      <div class="card" style="margin-top:20px">
        <h2>Admin Panel</h2>
        <div class="tabs">
          <div class="tab active" id="tabSlots">Slots</div>
          <div class="tab" id="tabUsers">Users</div>
          <div class="tab" id="tabBatch">Batch Create</div>
        </div>
        <div id="adminContent"></div>
      </div>`;
  }

  $('#app').innerHTML = `
    <div class="card">
      <div style="display:flex;justify-content:space-between;align-items:center">
        <h2>Welcome, ${u.username}</h2>
        <a id="logoutBtn" style="color:#888;cursor:pointer;font-size:0.9rem">Logout</a>
      </div>
      ${instanceHtml}
    </div>
    ${adminHtml}`;

  $('#logoutBtn').onclick = doLogout;
  if (!inst) $('#assignBtn').onclick = doAssign;
  if (isAdmin) {
    $('#tabSlots').onclick = () => { setActiveTab('tabSlots'); loadSlots(); };
    $('#tabUsers').onclick = () => { setActiveTab('tabUsers'); loadUsers(); };
    $('#tabBatch').onclick = () => { setActiveTab('tabBatch'); renderBatch(); };
    loadSlots();
  }
}

function setActiveTab(id) {
  document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
  $(`#${id}`).classList.add('active');
}

// ── Admin panel sub-views ──

async function loadSlots() {
  try {
    const slots = await api('GET', '/tenants');
    const rows = slots.map(s => `
      <tr>
        <td>${s.slot_id}</td>
        <td><span class="badge badge-${s.status}">${s.status}</span></td>
        <td>${s.assigned_username || '-'}</td>
        <td style="font-size:0.75rem">${s.gateway_token ? s.gateway_token.substring(0, 12) + '...' : '-'}</td>
      </tr>`).join('');
    $('#adminContent').innerHTML = `
      <table class="admin-table">
        <tr><th>Slot</th><th>Status</th><th>User</th><th>Token</th></tr>
        ${rows}
      </table>
      <p style="margin-top:12px;color:#888;font-size:0.85rem">
        ${slots.filter(s => s.status === 'available').length} available / ${slots.length} total
      </p>`;
  } catch (e) {
    $('#adminContent').innerHTML = `<p class="error">${e.message}</p>`;
  }
}

async function loadUsers() {
  try {
    const users = await api('GET', '/tenants/users');
    const rows = users.map(u => `
      <tr>
        <td>${u.username}</td>
        <td>${u.role}</td>
        <td>${u.slot_id || '-'}</td>
        <td style="font-size:0.75rem">${u.access_url ? '<a href="' + u.access_url + '" target="_blank">Open</a>' : '-'}</td>
      </tr>`).join('');
    $('#adminContent').innerHTML = `
      <table class="admin-table">
        <tr><th>Username</th><th>Role</th><th>Slot</th><th>Instance</th></tr>
        ${rows}
      </table>`;
  } catch (e) {
    $('#adminContent').innerHTML = `<p class="error">${e.message}</p>`;
  }
}

function renderBatch() {
  $('#adminContent').innerHTML = `
    <p style="margin-bottom:12px;color:#888">Create multiple users and assign instances in one click.</p>
    <input id="batchCount" type="number" value="10" min="1" max="50" placeholder="Number of users" />
    <input id="batchPrefix" value="user" placeholder="Username prefix (e.g. user → user-01, user-02)" />
    <button id="batchBtn">Create Users & Assign</button>
    <div id="batchResult" style="margin-top:16px"></div>`;
  $('#batchBtn').onclick = doBatch;
}

async function doBatch() {
  const count = parseInt($('#batchCount').value) || 10;
  const prefix = $('#batchPrefix').value || 'user';
  $('#batchBtn').disabled = true;
  $('#batchBtn').textContent = 'Creating...';
  try {
    const result = await api('POST', '/tenants/batch', { count, username_prefix: prefix });
    const rows = result.created.map(c => `
      <tr>
        <td>${c.username}</td>
        <td>${c.password}</td>
        <td>${c.slot_id || '-'}</td>
        <td style="font-size:0.75rem">${c.access_url ? '<a href="' + c.access_url + '" target="_blank">Open</a>' : (c.error || '-')}</td>
      </tr>`).join('');

    // CSV download
    const csv = 'username,password,slot_id,access_url,gateway_token\n' +
      result.created.map(c => `${c.username},${c.password},${c.slot_id},${c.access_url},${c.gateway_token || ''}`).join('\n');

    $('#batchResult').innerHTML = `
      <p class="success">Created ${result.created.length} users</p>
      <table class="admin-table">
        <tr><th>Username</th><th>Password</th><th>Slot</th><th>Instance</th></tr>
        ${rows}
      </table>
      <button class="btn-secondary" id="downloadCsv" style="margin-top:12px">Download CSV</button>`;
    $('#downloadCsv').onclick = () => {
      const blob = new Blob([csv], { type: 'text/csv' });
      const a = document.createElement('a');
      a.href = URL.createObjectURL(blob);
      a.download = 'workshop-users.csv';
      a.click();
    };
  } catch (e) {
    $('#batchResult').innerHTML = `<p class="error">${e.message}</p>`;
  }
  $('#batchBtn').disabled = false;
  $('#batchBtn').textContent = 'Create Users & Assign';
}

// ── Actions ──

async function doLogin() {
  const username = $('#username').value.trim();
  const password = $('#password').value;
  try {
    const data = await api('POST', '/login', { username, password });
    token = data.token;
    localStorage.setItem('token', token);
    await loadMe();
  } catch (e) {
    $('#error').textContent = e.message;
    $('#error').classList.remove('hidden');
  }
}

async function doRegister() {
  const username = $('#username').value.trim();
  const password = $('#password').value;
  try {
    const data = await api('POST', '/register', { username, password });
    token = data.token;
    localStorage.setItem('token', token);
    await loadMe();
  } catch (e) {
    $('#error').textContent = e.message;
    $('#error').classList.remove('hidden');
  }
}

async function doAssign() {
  $('#assignBtn').disabled = true;
  $('#assignBtn').textContent = 'Assigning...';
  try {
    await api('POST', '/assign');
    await loadMe();
  } catch (e) {
    const el = $('#assignError');
    if (el) { el.textContent = e.message; el.classList.remove('hidden'); }
    $('#assignBtn').disabled = false;
    $('#assignBtn').textContent = '🚀 Get My OpenClaw Instance';
  }
}

function doLogout() {
  token = '';
  currentUser = null;
  localStorage.removeItem('token');
  renderLogin();
}

async function loadMe() {
  try {
    currentUser = await api('GET', '/me');
    renderDashboard();
  } catch {
    token = '';
    localStorage.removeItem('token');
    renderLogin();
  }
}

// ── Init ──
if (token) { loadMe(); } else { renderLogin(); }
