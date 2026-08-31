const port = document.getElementById('port');
const token = document.getElementById('token');
const status = document.getElementById('status');

chrome.storage.local.get({ port: 9224, token: '' }).then((stored) => {
  port.value = String(stored.port);
  token.value = String(stored.token);
});

document.getElementById('save').addEventListener('click', async () => {
  const nextPort = Number(port.value);
  if (!Number.isInteger(nextPort) || nextPort <= 0 || nextPort > 65535) {
    status.textContent = 'invalid port';
    return;
  }
  if (!token.value) {
    status.textContent = 'token required';
    return;
  }
  await chrome.storage.local.set({ port: nextPort, token: token.value });
  status.textContent = 'saved';
  setTimeout(() => (status.textContent = ''), 1500);
});
