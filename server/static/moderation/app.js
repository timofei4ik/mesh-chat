const state = {csrf: '', status: 'new', reports: [], selected: null};
const $ = id => document.getElementById(id);
const escapeHtml = value => String(value ?? '').replace(
  /[&<>'"]/g,
  character => ({'&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;'}[character]),
);

async function api(path, options = {}) {
  const headers = {'Content-Type': 'application/json', ...(options.headers || {})};
  if (state.csrf) headers['X-CSRF-Token'] = state.csrf;
  const response = await fetch(path, {credentials: 'same-origin', ...options, headers});
  const body = await response.json().catch(() => ({ok: false}));
  if (!response.ok) throw new Error(body.error || 'request_failed');
  return body;
}

async function restore() {
  try {
    const session = await api('/admin/moderation/api/session');
    state.csrf = session.csrf;
    showDashboard();
    await loadReports();
  } catch (_) {
    showLogin();
  }
}

function showLogin() {
  $('loginView').classList.remove('hidden');
  $('dashboard').classList.add('hidden');
  $('logout').classList.add('hidden');
}

function showDashboard() {
  $('loginView').classList.add('hidden');
  $('dashboard').classList.remove('hidden');
  $('logout').classList.remove('hidden');
}

async function loadReports() {
  const body = await api(`/admin/moderation/api/reports?status=${encodeURIComponent(state.status)}`);
  state.reports = body.reports;
  if (state.selected) {
    state.selected = state.reports.find(
      report => report.report_id === state.selected.report_id,
    ) || null;
  }
  renderQueue();
  renderDetail();
}

function renderQueue() {
  const queue = $('queue');
  queue.innerHTML = state.reports.length
    ? state.reports.map(report => `
      <button class="report ${state.selected?.report_id === report.report_id ? 'active' : ''}"
              data-id="${escapeHtml(report.report_id)}">
        <strong>${escapeHtml(report.reason)} · ${escapeHtml(report.subject_type)}</strong>
        <small>${escapeHtml(report.target_login || report.subject_id)}</small>
        <small>${escapeHtml(report.created_at)}</small>
      </button>`).join('')
    : '<p class="empty">Очередь пуста</p>';
  queue.querySelectorAll('[data-id]').forEach(button => {
    button.onclick = () => {
      state.selected = state.reports.find(
        report => report.report_id === button.dataset.id,
      );
      renderQueue();
      renderDetail();
    };
  });
}

function actionButtons(report) {
  if (report.status === 'resolved') return '';
  const hideAllowed = ['message', 'comment', 'story', 'group', 'channel']
    .includes(report.subject_type);
  const accountAllowed = Boolean(report.target_login);
  return `
    <div class="actions">
      <button data-action="keep">Нарушения нет</button>
      <button data-action="needs_review">Передать на проверку</button>
      ${hideAllowed ? '<button data-action="hide" class="danger">Скрыть у всех</button>' : ''}
      ${accountAllowed ? '<button data-action="warn">Предупредить</button>' : ''}
      ${accountAllowed ? '<button data-action="restrict" class="danger">Ограничить</button>' : ''}
      ${accountAllowed ? '<button data-action="block" class="danger">Заблокировать</button>' : ''}
    </div>`;
}

function enforcementHistory(report) {
  const items = report.enforcements || [];
  if (!items.length) return '';
  return `
    <h3>Применённые меры</h3>
    <div class="enforcements">
      ${items.map(item => `
        <div class="enforcement">
          <div>
            <strong>${escapeHtml(item.action)}</strong>
            <small>${escapeHtml(item.status)} · ${escapeHtml(item.created_at)}</small>
            ${item.expires_at ? `<small>до ${escapeHtml(item.expires_at)}</small>` : ''}
          </div>
          ${item.reversible && item.status === 'active'
            ? `<button data-undo="${escapeHtml(item.enforcement_id)}">Отменить</button>`
            : ''}
        </div>`).join('')}
    </div>`;
}

function auditHistory(report) {
  const items = report.actions || [];
  if (!items.length) return '';
  return `
    <h3>Журнал решений</h3>
    <div class="audit">${items.map(item => `
      <div><strong>${escapeHtml(item.action)}</strong>
      <span>${escapeHtml(item.admin_id)} · ${escapeHtml(item.created_at)}</span>
      ${item.note ? `<p>${escapeHtml(item.note)}</p>` : ''}</div>`).join('')}</div>`;
}

function renderDetail() {
  const root = $('detail');
  const report = state.selected;
  if (!report) {
    root.className = 'detail panel empty';
    root.textContent = 'Выберите жалобу';
    return;
  }
  root.className = 'detail panel';
  root.innerHTML = `
    <h2>${escapeHtml(report.reason)}</h2>
    <div class="meta">
      <div><span>Объект</span>${escapeHtml(report.subject_type)} · ${escapeHtml(report.subject_id)}</div>
      <div><span>Статус</span>${escapeHtml(report.status)}</div>
      <div><span>Отправитель жалобы</span>${escapeHtml(report.reporter_login)}</div>
      <div><span>На кого</span>${escapeHtml(report.target_login || 'не указан')}</div>
      <div><span>Чат</span>${escapeHtml(report.conversation_id || 'не указан')}</div>
      <div><span>Создано</span>${escapeHtml(report.created_at)}</div>
    </div>
    <h3>Комментарий</h3>
    <div class="snapshot">${escapeHtml(report.details || 'Нет комментария')}</div>
    <h3>Переданный контекст</h3>
    <div class="snapshot">${escapeHtml(JSON.stringify(report.snapshot, null, 2))}</div>
    ${report.target_login && report.status !== 'resolved' ? `
      <label class="duration">Срок ограничения
        <select id="durationHours">
          <option value="1">1 час</option>
          <option value="24" selected>24 часа</option>
          <option value="168">7 дней</option>
          <option value="720">30 дней</option>
        </select>
      </label>` : ''}
    <textarea id="decisionNote" class="note" placeholder="Комментарий администратора"></textarea>
    <output id="decisionError"></output>
    ${actionButtons(report)}
    ${enforcementHistory(report)}
    ${auditHistory(report)}`;
  root.querySelectorAll('[data-action]').forEach(button => {
    button.onclick = () => decide(button.dataset.action);
  });
  root.querySelectorAll('[data-undo]').forEach(button => {
    button.onclick = () => undoEnforcement(button.dataset.undo);
  });
}

async function decide(action) {
  if (!state.selected) return;
  const error = $('decisionError');
  error.textContent = '';
  try {
    await api(`/admin/moderation/api/reports/${encodeURIComponent(state.selected.report_id)}/decision`, {
      method: 'POST',
      body: JSON.stringify({
        action,
        note: $('decisionNote').value,
        duration_hours: Number($('durationHours')?.value || 24),
      }),
    });
    state.selected = null;
    await loadReports();
  } catch (requestError) {
    error.textContent = requestError.message;
  }
}

async function undoEnforcement(enforcementId) {
  const error = $('decisionError');
  error.textContent = '';
  try {
    await api(`/admin/moderation/api/enforcements/${encodeURIComponent(enforcementId)}/undo`, {
      method: 'POST',
      body: JSON.stringify({note: $('decisionNote').value}),
    });
    await loadReports();
  } catch (requestError) {
    error.textContent = requestError.message;
  }
}

$('loginForm').onsubmit = async event => {
  event.preventDefault();
  $('loginError').textContent = '';
  try {
    const body = await api('/admin/moderation/api/login', {
      method: 'POST',
      body: JSON.stringify({password: $('password').value}),
    });
    state.csrf = body.csrf;
    $('password').value = '';
    showDashboard();
    await loadReports();
  } catch (error) {
    $('loginError').textContent = error.message === 'invalid_credentials'
      ? 'Неверный пароль'
      : 'Не удалось войти';
  }
};

$('logout').onclick = async () => {
  try {
    await api('/admin/moderation/api/logout', {method: 'POST', body: '{}'});
  } finally {
    state.csrf = '';
    showLogin();
  }
};

document.querySelectorAll('.tabs button').forEach(button => {
  button.onclick = async () => {
    state.status = button.dataset.status;
    state.selected = null;
    document.querySelectorAll('.tabs button').forEach(
      item => item.classList.toggle('active', item === button),
    );
    await loadReports();
  };
});

restore();
