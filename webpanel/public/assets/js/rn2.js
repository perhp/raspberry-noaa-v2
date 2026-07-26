/* raspberry-noaa-v2 webpanel — vanilla JS (no jQuery/Bootstrap) */

document.addEventListener('DOMContentLoaded', function () {
  // Dismissible alerts
  document.querySelectorAll('.alert .alert-close').forEach(function (btn) {
    btn.addEventListener('click', function () {
      btn.closest('.alert').remove();
    });
  });

  // Delete confirmation via native <dialog>.
  // Trigger buttons carry data-* fields; matching spans inside the dialog
  // are filled by data key, and the confirm link href comes from data-confirm-href.
  var dialog = document.getElementById('confirm-delete');
  if (!dialog) return;

  document.querySelectorAll('button[data-confirm-href]').forEach(function (btn) {
    btn.addEventListener('click', function () {
      dialog.querySelectorAll('[data-field]').forEach(function (el) {
        el.textContent = btn.dataset[el.dataset.field] || '';
      });
      dialog.querySelector('#confirm-deletion').setAttribute('href', btn.dataset.confirmHref);
      dialog.showModal();
    });
  });

  dialog.querySelector('.dialog-cancel').addEventListener('click', function () {
    dialog.close();
  });

  // Click on the backdrop closes the dialog
  dialog.addEventListener('click', function (e) {
    if (e.target === dialog) dialog.close();
  });
});
