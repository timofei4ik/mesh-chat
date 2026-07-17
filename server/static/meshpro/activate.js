const form = document.querySelector('#activation-form');
const loginInput = document.querySelector('#activation-login');
const passwordInput = document.querySelector('#activation-password');
const passwordToggle = document.querySelector('#activation-password-toggle');
const codeInput = document.querySelector('#activation-code');
const activateButton = document.querySelector('#activation-button');
const buttonLabel = activateButton.querySelector('.activation-button-label');
const errorOutput = document.querySelector('#activation-error');
const successOutput = document.querySelector('#activation-success');
const botLink = document.querySelector('#boosty-bot-link');

const errors = {
  invalid_credentials: 'Неверный логин или пароль MeshChat.',
  invalid_or_expired_code: 'Ключ неверный, уже использован или истёк.',
  boosty_not_configured: 'Активация MeshPro временно недоступна.',
  too_many_attempts: 'Слишком много попыток. Подождите несколько минут.',
  request_failed: 'Сервер не ответил. Проверьте подключение и попробуйте ещё раз.',
};

function showError(code, fallback) {
  errorOutput.textContent = errors[code] || fallback || 'Не удалось активировать MeshPro. Проверьте данные и попробуйте ещё раз.';
  errorOutput.hidden = false;
}

function clearError() {
  errorOutput.textContent = '';
  errorOutput.hidden = true;
}

function formatCode(value) {
  let raw = value.toUpperCase().replace(/[^A-Z0-9]/g, '');
  if (raw.startsWith('MPR')) raw = raw.slice(3);
  raw = raw.slice(0, 20);
  const groups = raw.match(/.{1,4}/g) || [];
  return raw ? `MPR-${groups.join('-')}` : '';
}

function setLoading(loading) {
  activateButton.disabled = loading;
  activateButton.classList.toggle('is-loading', loading);
  activateButton.setAttribute('aria-busy', String(loading));
  buttonLabel.textContent = loading ? 'Активируем…' : 'Активировать MeshPro';
}

codeInput.addEventListener('input', () => {
  const caretAtEnd = codeInput.selectionStart === codeInput.value.length;
  codeInput.value = formatCode(codeInput.value);
  if (caretAtEnd) codeInput.setSelectionRange(codeInput.value.length, codeInput.value.length);
  clearError();
});

for (const input of [loginInput, passwordInput]) {
  input.addEventListener('input', clearError);
}

passwordToggle.addEventListener('click', () => {
  const revealing = passwordInput.type === 'password';
  passwordInput.type = revealing ? 'text' : 'password';
  passwordToggle.textContent = revealing ? 'Скрыть' : 'Показать';
  passwordToggle.setAttribute('aria-pressed', String(revealing));
  passwordInput.focus({preventScroll: true});
});

form.addEventListener('submit', async (event) => {
  event.preventDefault();
  clearError();

  const login = loginInput.value.trim();
  const password = passwordInput.value;
  const code = formatCode(codeInput.value);

  if (!login) {
    showError('', 'Введите логин MeshChat.');
    loginInput.focus();
    return;
  }
  if (!password) {
    showError('', 'Введите пароль MeshChat.');
    passwordInput.focus();
    return;
  }
  if (code.length !== 28) {
    showError('invalid_or_expired_code');
    codeInput.focus();
    return;
  }

  setLoading(true);
  try {
    const response = await fetch('/billing/boosty/activate', {
      method: 'POST',
      cache: 'no-store',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({login, password, code}),
    });
    const result = await response.json().catch(() => ({}));
    if (!response.ok || !result.ok) throw new Error(result.error || 'request_failed');

    passwordInput.value = '';
    codeInput.value = '';
    form.hidden = true;
    botLink.hidden = true;

    const duration = Number(result.duration_days || 0);
    const successTitle = successOutput.querySelector('strong');
    const successText = successOutput.querySelector('p');
    if (duration > 0) {
      successTitle.textContent = `MeshPro активирован на ${duration} дней`;
      successText.textContent = 'Вернитесь в MeshChat или MeshPrivacy и обновите статус подписки.';
    }
    successOutput.hidden = false;
    successOutput.focus({preventScroll: false});
  } catch (error) {
    showError(error.message);
    setLoading(false);
  }
});

async function loadBotInfo() {
  try {
    const response = await fetch('/billing/boosty/info', {cache: 'no-store'});
    const result = await response.json();
    if (!response.ok || !result.ok || !result.bot_username) return;
    const botUsername = String(result.bot_username).trim().replace(/^@/, '');
    if (!botUsername) return;
    botLink.href = `https://t.me/${encodeURIComponent(botUsername)}`;
    botLink.hidden = false;
  } catch (_) {
    // Activation remains available when public bot information is unavailable.
  }
}

function startOrbBackground() {
  const canvas = document.querySelector('#activation-orbs');
  const context = canvas.getContext('2d', {alpha: false});
  const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
  const spheres = [
    {x: 0.12, y: 0.18, radius: 0.42, color: [56, 213, 255], phase: 0.2, alpha: 0.25, speed: 0.00010},
    {x: 0.88, y: 0.28, radius: 0.46, color: [165, 108, 255], phase: 2.1, alpha: 0.23, speed: 0.000085},
    {x: 0.52, y: 0.92, radius: 0.55, color: [49, 93, 255], phase: 4.2, alpha: 0.13, speed: 0.000065},
  ];
  let width = 0;
  let height = 0;
  let pixelRatio = 1;
  let frameHandle = 0;
  let lastFrame = 0;

  function resize() {
    pixelRatio = Math.min(window.devicePixelRatio || 1, 1.5);
    width = Math.max(320, window.innerWidth);
    height = Math.max(480, window.innerHeight);
    canvas.width = Math.round(width * pixelRatio);
    canvas.height = Math.round(height * pixelRatio);
    canvas.style.width = `${width}px`;
    canvas.style.height = `${height}px`;
    context.setTransform(pixelRatio, 0, 0, pixelRatio, 0, 0);
    draw(performance.now());
  }

  function drawGlow(x, y, radius, color, alpha) {
    const gradient = context.createRadialGradient(x, y, 0, x, y, radius);
    gradient.addColorStop(0, `rgba(${color.join(',')},${alpha})`);
    gradient.addColorStop(0.34, `rgba(${color.join(',')},${alpha * 0.46})`);
    gradient.addColorStop(1, `rgba(${color.join(',')},0)`);
    context.fillStyle = gradient;
    context.fillRect(x - radius, y - radius, radius * 2, radius * 2);
  }

  function draw(time) {
    context.fillStyle = '#07111e';
    context.fillRect(0, 0, width, height);
    const shortest = Math.min(width, height);

    for (const sphere of spheres) {
      const phase = time * sphere.speed * Math.PI * 2 + sphere.phase;
      const radius = shortest * sphere.radius;
      const x = width * sphere.x + Math.cos(phase) * radius * 0.12;
      const y = height * sphere.y + Math.sin(phase * 0.82) * radius * 0.10;
      const pulse = reducedMotion.matches ? 0.82 : 0.72 + Math.sin(phase * 1.3) * 0.18;
      drawGlow(x, y, radius * 1.55, sphere.color, sphere.alpha * pulse);
      drawGlow(x, y, radius * 0.55, sphere.color, sphere.alpha * 0.62 * pulse);
    }

    context.fillStyle = 'rgba(2,6,16,0.22)';
    context.fillRect(0, 0, width, height);
  }

  function animate(time) {
    frameHandle = 0;
    if (document.hidden || reducedMotion.matches) return;
    if (time - lastFrame >= 33) {
      draw(time);
      lastFrame = time;
    }
    frameHandle = window.requestAnimationFrame(animate);
  }

  function syncAnimation() {
    if (frameHandle) window.cancelAnimationFrame(frameHandle);
    frameHandle = 0;
    draw(performance.now());
    if (!document.hidden && !reducedMotion.matches) {
      frameHandle = window.requestAnimationFrame(animate);
    }
  }

  window.addEventListener('resize', resize, {passive: true});
  document.addEventListener('visibilitychange', syncAnimation);
  reducedMotion.addEventListener?.('change', syncAnimation);
  resize();
  syncAnimation();
}

const requestedLogin = new URLSearchParams(window.location.search).get('login');
if (requestedLogin) loginInput.value = requestedLogin;

loadBotInfo();
startOrbBackground();
