const LANGUAGE_KEY = "agentSignalBar.language";
const THEME_KEY = "agentSignalBar.theme";

const copy = {
  en: {
    "meta.title": "Agent Signal Bar - Local status lights for AI agents on macOS",
    "meta.description":
      "Agent Signal Bar is a local-first macOS menu bar app that shows Codex Desktop, Claude Code, and local script activity with red, yellow, and green status lights.",
    "nav.label": "Primary navigation",
    "nav.features": "Features",
    "nav.install": "Install",
    "nav.privacy": "Privacy",
    "nav.download": "Download",
    "controls.label": "Site display options",
    "language.label": "Language",
    "theme.toDark": "Switch to dark mode",
    "theme.toLight": "Switch to light mode",
    "hero.subtitle": "Local status lights for AI agents on macOS.",
    "hero.body":
      "Keep Codex Desktop, Claude Code, and local automation visible from the menu bar. Green means work is moving, yellow asks for attention, and red means you need to step in.",
    "hero.download": "Download for macOS",
    "hero.source": "View source",
    "hero.runAria": "Install command",
    "hero.note": "Free and open source. macOS 14+. Ad-hoc signed release builds today.",
    "copy.run": "Copy install command",
    "copy.brew": "Copy Homebrew install command",
    "copy.build": "Copy build command",
    "integrations.label": "Supported local agent inputs",
    "integrations.title": "Works with the tools already running locally.",
    "integrations.body": "No dashboard account, no cloud relay, no hidden service.",
    "integrations.tested": "Tested & adapted",
    "integrations.untested": "Not tested",
    "integrations.codexTitle": "Codex Desktop",
    "integrations.codexBody": "Local session log monitoring without required hooks.",
    "integrations.claudeTitle": "Claude Code",
    "integrations.claudeBody": "Optional hook events for live agent state.",
    "integrations.scriptsTitle": "Local scripts",
    "integrations.scriptsBody": "Write JSON events or wrap any command.",
    "integrations.cliTitle": "Agent CLI",
    "integrations.cliBody": "Update, inspect, clear, and reset status from shell.",
    "features.title": "A tiny signal language for busy agent work.",
    "features.body":
      "Agent Signal Bar turns noisy agent progress into a glanceable menu bar signal. It protects permission, blocked, and attention states so urgent work is not overwritten by normal background activity.",
    "features.mediaAlt": "Animated preview of Agent Signal Bar light effects",
    "install.title": "Install",
    "install.body":
      "Use Homebrew for the quickest install, download the DMG from GitHub Releases, or run the SwiftPM app directly from the checkout.",
    "install.caskTitle": "Homebrew",
    "install.caskAria": "Homebrew install command",
    "install.caskHint": "Installs the latest published release through the guan-ops Homebrew tap.",
    "install.releaseTitle": "Download release",
    "install.step1": "Open the latest GitHub Release.",
    "install.step2": "Download <code>AgentSignalLight-local.dmg</code>.",
    "install.step3": "Drag the app to Applications and launch it.",
    "install.openRelease": "Open latest release",
    "install.sourceTitle": "Run from source",
    "install.buildAria": "Build and run command",
    "install.sourceHint": "Use the verification flag when you want startup checks after the build.",
    "signal.titleLine1": "Red, yellow, green.",
    "signal.titleLine2": "The right interrupt at the right time.",
    "signal.tableLabel": "Signal state meanings",
    "signal.green": "Green",
    "signal.greenBody": "Idle, thinking, working, tool done, or complete.",
    "signal.yellow": "Yellow",
    "signal.yellowBody": "Attention, notification, or stale state worth checking.",
    "signal.red": "Red",
    "signal.redBody": "Permission request, blocked state, failure, or error.",
    "privacy.title": "Local-first by design.",
    "privacy.body":
      "Status files, hook events, Codex Desktop session parsing, and diagnostics stay on your Mac. The app does not require a cloud account or telemetry backend to do its job.",
    "privacy.item1": "State is read from local files and local agent logs.",
    "privacy.item2": "Hooks are optional for Codex Desktop and useful for CLI/TUI workflows.",
    "privacy.item3": "Diagnostics export is a local file you control.",
    "privacy.settingsAlt": "Agent Signal Bar settings window with Liquid Glass enabled",
    "compare.title": "Built for the menu bar, not another tab.",
    "compare.body": "Choose detailed panels when you want context, or a simple native menu when you only need quick actions.",
    "compare.simpleAlt": "Simple Agent Signal Bar native menu",
    "compare.solidAlt": "Agent Signal Bar settings window with Liquid Glass enabled",
    "footer.builtBy": "Built by XiongYang Guan",
  },
  zh: {
    "meta.title": "Agent Signal Bar - macOS 本地 AI Agent 状态灯",
    "meta.description":
      "Agent Signal Bar 是一款本地优先的 macOS 菜单栏应用，用红、黄、绿状态灯显示 Codex Desktop、Claude Code 和本地脚本活动。",
    "nav.label": "主导航",
    "nav.features": "功能",
    "nav.install": "安装",
    "nav.privacy": "隐私",
    "nav.download": "下载",
    "controls.label": "站点显示选项",
    "language.label": "语言",
    "theme.toDark": "切换到深色模式",
    "theme.toLight": "切换到浅色模式",
    "hero.subtitle": "macOS 上的本地 AI Agent 状态灯",
    "hero.body":
      "把 Codex Desktop、Claude Code 和本地自动化状态留在菜单栏里。绿色表示正在推进，黄色表示需要留意，红色表示需要你介入。",
    "hero.download": "下载 macOS 版",
    "hero.source": "查看源码",
    "hero.runAria": "安装命令",
    "hero.note": "免费开源。支持 macOS 14+。当前发布构建为临时签名。",
    "copy.run": "复制安装命令",
    "copy.brew": "复制 Homebrew 安装命令",
    "copy.build": "复制构建命令",
    "integrations.label": "支持的本地 Agent 输入",
    "integrations.title": "配合已经在本机运行的工具。",
    "integrations.body": "不需要仪表盘账号，不经过云端中继，也没有隐藏服务。",
    "integrations.tested": "已测试适配",
    "integrations.untested": "尚未测试",
    "integrations.codexTitle": "Codex Desktop",
    "integrations.codexBody": "无需强制 hooks，也能监控本地会话日志。",
    "integrations.claudeTitle": "Claude Code",
    "integrations.claudeBody": "可选 hook 事件，用于实时 Agent 状态。",
    "integrations.scriptsTitle": "本地脚本",
    "integrations.scriptsBody": "写入 JSON 事件，或包装任意命令。",
    "integrations.cliTitle": "Agent CLI",
    "integrations.cliBody": "从命令行更新、检查、清除和重置状态。",
    "features.title": "给繁忙 Agent 工作流的一套小型信号语言",
    "features.body":
      "Agent Signal Bar 把嘈杂的 Agent 进度压缩成一眼能看懂的菜单栏信号，并保护授权、阻塞、提醒等重要状态，不让普通后台活动覆盖它们。",
    "features.mediaAlt": "Agent Signal Bar 灯效动画预览",
    "install.title": "安装",
    "install.body": "优先使用 Homebrew，也可以从 GitHub Releases 下载 DMG，或直接在源码目录运行 SwiftPM 应用",
    "install.caskTitle": "Homebrew",
    "install.caskAria": "Homebrew 安装命令",
    "install.caskHint": "通过 guan-ops Homebrew tap 安装最新发布版",
    "install.releaseTitle": "下载发布版",
    "install.step1": "打开最新 GitHub Release。",
    "install.step2": "下载 <code>AgentSignalLight-local.dmg</code>。",
    "install.step3": "拖入 Applications 后启动应用。",
    "install.openRelease": "打开最新发布版",
    "install.sourceTitle": "从源码运行",
    "install.buildAria": "构建并运行命令",
    "install.sourceHint": "需要构建后启动检查时，使用验证参数。",
    "signal.titleLine1": "红、黄、绿",
    "signal.titleLine2": "在正确的时刻给出正确提醒",
    "signal.tableLabel": "状态灯含义",
    "signal.green": "绿色",
    "signal.greenBody": "空闲、思考、工作、工具完成或任务完成。",
    "signal.yellow": "黄色",
    "signal.yellowBody": "提醒、通知，或值得检查的过期状态。",
    "signal.red": "红色",
    "signal.redBody": "授权请求、阻塞、失败或错误。",
    "privacy.title": "默认本地优先",
    "privacy.body":
      "状态文件、hook 事件、Codex Desktop 会话解析和诊断信息都留在你的 Mac 上。应用不需要云端账号或遥测后端也能完成工作。",
    "privacy.item1": "状态来自本地文件和本地 Agent 日志。",
    "privacy.item2": "Codex Desktop 不强制 hooks；CLI/TUI 工作流可按需使用 hooks。",
    "privacy.item3": "诊断导出是你自己控制的本地文件。",
    "privacy.settingsAlt": "开启 Liquid Glass 的 Agent Signal Bar 设置窗口",
    "compare.title": "为菜单栏而生，不再多开一个标签页",
    "compare.body": "需要上下文时看详细面板，只想快速操作时用简单原生菜单。",
    "compare.simpleAlt": "Agent Signal Bar 简单原生菜单",
    "compare.solidAlt": "开启 Liquid Glass 的 Agent Signal Bar 设置窗口",
    "footer.builtBy": "Built by XiongYang Guan",
  },
};

const languageButtons = document.querySelectorAll("[data-language-option]");
const themeToggle = document.querySelector("[data-theme-toggle]");
const themeColorMeta = document.querySelector('meta[name="theme-color"]');
const descriptionMeta = document.querySelector('meta[name="description"]');
const ogDescriptionMeta = document.querySelector('meta[property="og:description"]');
const ogImageMeta = document.querySelector('meta[property="og:image"]');
const systemTheme = window.matchMedia("(prefers-color-scheme: dark)");

function readStorage(key) {
  try {
    return localStorage.getItem(key);
  } catch {
    return null;
  }
}

function writeStorage(key, value) {
  try {
    localStorage.setItem(key, value);
  } catch {
    // Ignore storage failures; the controls still work for the current page view.
  }
}

function preferredLanguage() {
  const stored = readStorage(LANGUAGE_KEY);
  if (stored === "en" || stored === "zh") return stored;
  return navigator.language.toLowerCase().startsWith("zh") ? "zh" : "en";
}

function preferredTheme() {
  const stored = readStorage(THEME_KEY);
  if (stored === "dark" || stored === "light") return stored;
  return systemTheme.matches ? "dark" : "light";
}

function applyLanguage(language) {
  const dictionary = copy[language] || copy.en;

  document.documentElement.lang = language === "zh" ? "zh-CN" : "en";
  document.documentElement.dataset.language = language;
  document.title = dictionary["meta.title"];
  descriptionMeta?.setAttribute("content", dictionary["meta.description"]);
  ogDescriptionMeta?.setAttribute("content", dictionary["meta.description"]);
  ogImageMeta?.setAttribute(
    "content",
    language === "zh" ? "./assets/menu-bar-panel-detailed-zh-CN.png" : "./assets/menu-bar-panel-detailed-en.png",
  );

  document.querySelectorAll("[data-i18n]").forEach((element) => {
    const value = dictionary[element.dataset.i18n];
    if (value !== undefined) element.textContent = value;
  });

  document.querySelectorAll("[data-i18n-html]").forEach((element) => {
    const value = dictionary[element.dataset.i18nHtml];
    if (value !== undefined) element.innerHTML = value;
  });

  document.querySelectorAll("[data-i18n-alt]").forEach((element) => {
    const value = dictionary[element.dataset.i18nAlt];
    if (value !== undefined) element.setAttribute("alt", value);
  });

  document.querySelectorAll("[data-i18n-aria-label]").forEach((element) => {
    const value = dictionary[element.dataset.i18nAriaLabel];
    if (value !== undefined) element.setAttribute("aria-label", value);
  });

  document.querySelectorAll("[data-src-en][data-src-zh]").forEach((element) => {
    const nextSource = language === "zh" ? element.dataset.srcZh : element.dataset.srcEn;
    if (nextSource && element.getAttribute("src") !== nextSource) {
      element.setAttribute("src", nextSource);
    }
  });

  languageButtons.forEach((button) => {
    const isActive = button.dataset.languageOption === language;
    button.classList.toggle("is-active", isActive);
    button.setAttribute("aria-pressed", isActive ? "true" : "false");
  });

  updateThemeLabel();
}

function applyTheme(theme, { persist = true } = {}) {
  const nextTheme = theme === "dark" ? "dark" : "light";
  document.documentElement.dataset.theme = nextTheme;
  document.documentElement.style.colorScheme = nextTheme;
  themeColorMeta?.setAttribute("content", nextTheme === "dark" ? "#0e1013" : "#ffffff");
  themeToggle?.setAttribute("aria-pressed", nextTheme === "dark" ? "true" : "false");
  if (persist) writeStorage(THEME_KEY, nextTheme);
  updateThemeLabel();
}

function updateThemeLabel() {
  if (!themeToggle) return;
  const language = document.documentElement.dataset.language === "zh" ? "zh" : "en";
  const dictionary = copy[language];
  const isDark = document.documentElement.dataset.theme === "dark";
  const label = isDark ? dictionary["theme.toLight"] : dictionary["theme.toDark"];
  themeToggle.setAttribute("aria-label", label);
  themeToggle.title = label;
}

languageButtons.forEach((button) => {
  button.addEventListener("click", () => {
    const language = button.dataset.languageOption === "zh" ? "zh" : "en";
    writeStorage(LANGUAGE_KEY, language);
    applyLanguage(language);
  });
});

themeToggle?.addEventListener("click", () => {
  const currentTheme = document.documentElement.dataset.theme === "dark" ? "dark" : "light";
  applyTheme(currentTheme === "dark" ? "light" : "dark");
});

systemTheme.addEventListener("change", (event) => {
  if (readStorage(THEME_KEY)) return;
  applyTheme(event.matches ? "dark" : "light", { persist: false });
});

document.querySelectorAll("[data-copy-target]").forEach((button) => {
  button.addEventListener("click", async () => {
    const target = document.getElementById(button.dataset.copyTarget);
    if (!target) return;

    const text = target.textContent.trim();
    try {
      await navigator.clipboard.writeText(text);
    } catch {
      const helper = document.createElement("textarea");
      helper.value = text;
      helper.setAttribute("readonly", "");
      helper.style.position = "fixed";
      helper.style.left = "-9999px";
      document.body.appendChild(helper);
      helper.select();
      document.execCommand("copy");
      helper.remove();
    }

    button.classList.add("is-copied");
    window.setTimeout(() => button.classList.remove("is-copied"), 1300);
  });
});

applyTheme(preferredTheme(), { persist: false });
applyLanguage(preferredLanguage());
