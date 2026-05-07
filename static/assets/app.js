(() => {
  const state = { hero: 'bash', install: 'macos' };
  const commands = {
    bash: 'curl -fsSL https://raw.githubusercontent.com/hendriknielaender/zvm/main/install.sh | bash',
    brew: 'brew tap hendriknielaender/zvm && brew install zvm',
    macos: 'brew tap hendriknielaender/zvm && brew install zvm',
    linux: 'curl -fsSL https://raw.githubusercontent.com/hendriknielaender/zvm/main/install.sh | bash',
    windows: 'irm https://raw.githubusercontent.com/hendriknielaender/zvm/master/install.ps1 | iex',
  };

  const copy = async (button, text) => {
    await navigator.clipboard.writeText(text);
    const previous = button.dataset.icon || 'copy';
    button.dataset.icon = 'check';
    button.setAttribute('aria-label', 'Copied');
    button.classList.add('copied');
    setTimeout(() => {
      button.dataset.icon = previous;
      button.setAttribute('aria-label', 'Copy to clipboard');
      button.classList.remove('copied');
    }, 1600);
  };

  document.querySelectorAll('[data-copy]').forEach((button) => {
    button.addEventListener('click', () => copy(button, button.dataset.copy));
  });

  document.querySelectorAll('[data-hero-tab]').forEach((button) => {
    button.addEventListener('click', () => {
      state.hero = button.dataset.heroTab;
      document.querySelectorAll('[data-hero-tab]').forEach((tab) => tab.classList.toggle('active', tab === button));
      document.querySelector('[data-hero-copy]').dataset.copy = commands[state.hero];
      document.querySelectorAll('[data-hero-panel]').forEach((panel) => panel.hidden = panel.dataset.heroPanel !== state.hero);
    });
  });

  document.querySelectorAll('[data-install-tab]').forEach((button) => {
    button.addEventListener('click', () => {
      state.install = button.dataset.installTab;
      document.querySelectorAll('[data-install-tab]').forEach((tab) => tab.classList.toggle('active', tab === button));
      document.querySelector('[data-install-copy]').dataset.copy = commands[state.install];
      document.querySelectorAll('[data-install-panel]').forEach((panel) => panel.hidden = panel.dataset.installPanel !== state.install);
    });
  });

  const sectionIds = ['installation', 'usage', 'auto-version', 'configuration'];
  const navItems = Array.from(document.querySelectorAll('[data-section-link]'));
  const updateActiveSection = () => {
    let current = 'installation';
    for (const id of sectionIds) {
      const section = document.getElementById(id);
      if (section && section.getBoundingClientRect().top <= 150) current = id;
    }
    navItems.forEach((item) => item.classList.toggle('active', item.hash === `#${current}`));
  };
  updateActiveSection();
  document.addEventListener('scroll', updateActiveSection, { passive: true });
})();
