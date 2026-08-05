/* raspberry-noaa-v2 webpanel — vanilla JS (no jQuery/Bootstrap) */

document.addEventListener('DOMContentLoaded', function () {
  // Dismissible alerts
  document.querySelectorAll('.alert .alert-close').forEach(function (btn) {
    btn.addEventListener('click', function () {
      btn.closest('.alert').remove();
    });
  });

  // Disclosure buttons: show/hide the section named by aria-controls and swap the
  // button's label between its data-label-more and data-label-less strings. The
  // section stays [hidden] until asked for, so lazy images inside it stay unfetched.
  document.querySelectorAll('button[aria-controls][data-label-less]').forEach(function (btn) {
    btn.addEventListener('click', function () {
      var target = document.getElementById(btn.getAttribute('aria-controls'));
      if (!target) return;

      var opening = target.hasAttribute('hidden');
      if (opening) {
        target.removeAttribute('hidden');
      } else {
        target.setAttribute('hidden', '');
      }
      btn.setAttribute('aria-expanded', opening ? 'true' : 'false');

      var label = btn.querySelector('.disclose-text');
      if (label) label.textContent = opening ? btn.dataset.labelLess : btn.dataset.labelMore;
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
