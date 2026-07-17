const form = document.querySelector('#checkout-form');
const loginInput = document.querySelector('#login');
const emailInput = document.querySelector('#email');
const checkoutButton = document.querySelector('#checkout-button');
const formError = document.querySelector('#form-error');
const periodDays = document.querySelector('#period-days');
const planDays = document.querySelector('#plan-days');
const planPrice = document.querySelector('#plan-price');

const errorMessages = {
  'account does not exist': 'Аккаунт с таким логином не найден.',
  'invalid email': 'Проверьте адрес электронной почты.',
  'billing is not configured': 'Оплата временно недоступна.',
  'the VPN backend is not ready': 'MeshPro временно недоступен.',
  too_many_attempts: 'Слишком много попыток. Подождите несколько минут.',
};

function showError(message) {
  formError.textContent = errorMessages[message] || 'Не удалось открыть оплату. Попробуйте ещё раз.';
  formError.hidden = false;
}

function clearError() {
  formError.textContent = '';
  formError.hidden = true;
}

function formatPrice(value, currency) {
  const amount = Number(value);
  if (!Number.isFinite(amount)) return '—';
  return new Intl.NumberFormat('ru-RU', {
    style: 'currency',
    currency: currency || 'RUB',
    maximumFractionDigits: 0,
  }).format(amount);
}

async function loadOffer() {
  try {
    const response = await fetch('/billing/offer', {cache: 'no-store'});
    const offer = await response.json();
    if (!response.ok || !offer.ok) throw new Error();
    periodDays.textContent = String(offer.period_days);
    planDays.textContent = String(offer.period_days);
    planPrice.textContent = formatPrice(offer.price_value, offer.currency);
  } catch (_) {
    checkoutButton.disabled = true;
    showError('billing is not configured');
  }
}

form.addEventListener('submit', async (event) => {
  event.preventDefault();
  clearError();
  const login = loginInput.value.trim();
  const email = emailInput.value.trim();
  if (!login) {
    showError('account does not exist');
    loginInput.focus();
    return;
  }
  if (!email || !emailInput.validity.valid) {
    showError('invalid email');
    emailInput.focus();
    return;
  }

  checkoutButton.disabled = true;
  checkoutButton.textContent = 'Создаём счёт…';
  try {
    const response = await fetch('/billing/checkout', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({login, email}),
    });
    const result = await response.json();
    if (!response.ok || !result.ok) {
      throw new Error(result.error || 'request_failed');
    }
    const paymentUrl = result.checkout?.confirmation_url;
    if (!paymentUrl) throw new Error('request_failed');
    window.location.assign(paymentUrl);
  } catch (error) {
    showError(error.message);
    checkoutButton.disabled = false;
    checkoutButton.textContent = 'Перейти к оплате';
  }
});

const requestedLogin = new URLSearchParams(window.location.search).get('login');
if (requestedLogin) loginInput.value = requestedLogin;
loadOffer();
