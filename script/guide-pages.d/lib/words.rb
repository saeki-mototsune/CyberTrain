# The UI words of the guide pages, per language: what the generator adds
# around the content (the Markdown carries only the markers). Plain text, as
# written on the existing site/<lang>/tutorial.html pages (French keeps its
# no-break spaces before ":"); the renderer escapes them. `contents` (the
# default heading of the contents list) has no counterpart on today's pages.
#
#   why          p.why's why-k                  here, here_sep  p.stage's stage-k and its sr-only ":"
#   rule         callout-k of > [!RULE]         compile         callout-k of > [!COMPILE]
#   example      callout-k of > [!EXAMPLE]      aria_sep        between a callout's kind and title in its aria-label
#   code_label   a code figure's aria-label prefix (GuidePages::Highlight)
#   contents     contents heading when the front matter has no toc_title
#   skip, guides, lang_label, home   the skip link, the Guides nav entry, the
#                language menu's aria-label, the brand link's aria-label
#   cmp_caption  the visually hidden caption of a <!-- table: cmp --> table
# The page shell (layout.html.erb), as on site/<lang>/tutorial.html:
#   primary, how, tutorial, deploy, playground   the header nav's aria-label and entries
#   steps_label  the contents list's aria-label on the tutorial (nav: tutorial)
#   tagline, project, related, related_label, language, languages_label,
#   license, prealpha, independent               the footer

module GuidePages
  WORDS = {
    "en" => {
      why: "Why", rule: "Spinel rule", compile: "Before it compiles", example: "From the finished example",
      here: "You are here", here_sep: ":", aria_sep: ": ", code_label: "Code: ",
      contents: "Contents", skip: "Skip to content", guides: "Guides",
      lang_label: "Language: English", home: "CyberTrain home",
      cmp_caption: "Differences between Rails and CyberTrain (full table from the README)",
      primary: "Primary", how: "How it works", tutorial: "Tutorial", deploy: "Deploy", playground: "Playground",
      steps_label: "Tutorial steps", tagline: "Rails-shaped web apps, compiled to one native binary.",
      project: "Project", related: "Related", related_label: "Related projects", language: "Language", languages_label: "Languages",
      license: "MIT License", prealpha: "Pre-alpha", independent: "CyberTrain is an independent project, not affiliated with Rails, Spinel or Roundhouse.",
    },
    "ja" => {
      why: "なぜ", rule: "Spinel のルール", compile: "コンパイルする前に", example: "完成版のサンプルから",
      here: "現在地", here_sep: ":", aria_sep: "：", code_label: "コード：",
      contents: "目次", skip: "本文へスキップ", guides: "ガイド",
      lang_label: "言語: 日本語", home: "CyberTrain ホーム",
      cmp_caption: "Rails と CyberTrain の違い（README の完全な表）",
      primary: "メイン", how: "仕組み", tutorial: "チュートリアル", deploy: "デプロイ", playground: "試す",
      steps_label: "チュートリアルのステップ", tagline: "Rails 流の Web アプリを、ひとつのネイティブバイナリに。",
      project: "プロジェクト", related: "関連", related_label: "関連プロジェクト", language: "言語", languages_label: "言語",
      license: "MIT ライセンス", prealpha: "プレアルファ", independent: "CyberTrain は独立したプロジェクトであり、Rails、Spinel、Roundhouse とは提携関係にありません。",
    },
    "zh" => {
      why: "为什么", rule: "Spinel 规则", compile: "编译之前", example: "来自完成后的示例",
      here: "当前位置", here_sep: "：", aria_sep: "：", code_label: "代码：",
      contents: "目录", skip: "跳到主要内容", guides: "指南",
      lang_label: "语言：简体中文", home: "CyberTrain 首页",
      cmp_caption: "Rails 与 CyberTrain 的差异（README 中的完整表格）",
      primary: "主导航", how: "原理", tutorial: "教程", deploy: "部署", playground: "在线试用",
      steps_label: "教程步骤", tagline: "Rails 风格的 Web 应用，编译为单个原生二进制文件。",
      project: "项目", related: "相关", related_label: "相关项目", language: "语言", languages_label: "语言",
      license: "MIT 许可证", prealpha: "预 Alpha 版", independent: "CyberTrain 是一个独立项目，与 Rails、Spinel 或 Roundhouse 均无关联。",
    },
    "ru" => {
      why: "Зачем", rule: "Правило Spinel", compile: "Чтобы скомпилировалось", example: "Из готового примера",
      here: "Вы здесь", here_sep: ":", aria_sep: ": ", code_label: "Код: ",
      contents: "Содержание", skip: "Перейти к содержимому", guides: "Руководства",
      lang_label: "Язык: русский", home: "CyberTrain — главная",
      cmp_caption: "Различия между Rails и CyberTrain (полная таблица из README)",
      primary: "Основная навигация", how: "Как это работает", tutorial: "Учебник", deploy: "Деплой", playground: "Песочница",
      steps_label: "Шаги учебника", tagline: "Веб-приложения в духе Rails, скомпилированные в один нативный бинарный файл.",
      project: "Проект", related: "Связанные", related_label: "Связанные проекты", language: "Язык", languages_label: "Языки",
      license: "Лицензия MIT", prealpha: "Пре-альфа", independent: "CyberTrain — независимый проект, не связанный с Rails, Spinel или Roundhouse.",
    },
    "fr" => {
      why: "Pourquoi", rule: "Règle Spinel", compile: "Avant de compiler", example: "Tiré de l’exemple final",
      here: "Vous êtes ici", here_sep: " :", aria_sep: " : ", code_label: "Code : ",
      contents: "Sommaire", skip: "Aller au contenu", guides: "Guides",
      lang_label: "Langue : français", home: "Accueil CyberTrain",
      cmp_caption: "Différences entre Rails et CyberTrain (tableau complet du README)",
      primary: "Navigation principale", how: "Fonctionnement", tutorial: "Tutoriel", deploy: "Déployer", playground: "Essayer",
      steps_label: "Étapes du tutoriel", tagline: "Des applications web à la Rails, compilées en un seul binaire natif.",
      project: "Projet", related: "Voir aussi", related_label: "Projets liés", language: "Langue", languages_label: "Langues",
      license: "Licence MIT", prealpha: "Pré-alpha", independent: "CyberTrain est un projet indépendant, sans lien avec Rails, Spinel ou Roundhouse.",
    },
  }.freeze
end
