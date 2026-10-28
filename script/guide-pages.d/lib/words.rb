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

module GuidePages
  WORDS = {
    "en" => {
      why: "Why", rule: "Spinel rule", compile: "Before it compiles", example: "From the finished example",
      here: "You are here", here_sep: ":", aria_sep: ": ", code_label: "Code: ",
      contents: "Contents", skip: "Skip to content", guides: "Guides",
      lang_label: "Language: English", home: "CyberTrain home",
      cmp_caption: "Differences between Rails and CyberTrain (full table from the README)",
    },
    "ja" => {
      why: "なぜ", rule: "Spinel のルール", compile: "コンパイルする前に", example: "完成版のサンプルから",
      here: "現在地", here_sep: ":", aria_sep: "：", code_label: "コード：",
      contents: "目次", skip: "本文へスキップ", guides: "ガイド",
      lang_label: "言語: 日本語", home: "CyberTrain ホーム",
      cmp_caption: "Rails と CyberTrain の違い（README の完全な表）",
    },
    "zh" => {
      why: "为什么", rule: "Spinel 规则", compile: "编译之前", example: "来自完成后的示例",
      here: "当前位置", here_sep: "：", aria_sep: "：", code_label: "代码：",
      contents: "目录", skip: "跳到主要内容", guides: "指南",
      lang_label: "语言：简体中文", home: "CyberTrain 首页",
      cmp_caption: "Rails 与 CyberTrain 的差异（README 中的完整表格）",
    },
    "ru" => {
      why: "Зачем", rule: "Правило Spinel", compile: "Чтобы скомпилировалось", example: "Из готового примера",
      here: "Вы здесь", here_sep: ":", aria_sep: ": ", code_label: "Код: ",
      contents: "Содержание", skip: "Перейти к содержимому", guides: "Руководства",
      lang_label: "Язык: русский", home: "CyberTrain — главная",
      cmp_caption: "Различия между Rails и CyberTrain (полная таблица из README)",
    },
    "fr" => {
      why: "Pourquoi", rule: "Règle Spinel", compile: "Avant de compiler", example: "Tiré de l’exemple final",
      here: "Vous êtes ici", here_sep: " :", aria_sep: " : ", code_label: "Code : ",
      contents: "Sommaire", skip: "Aller au contenu", guides: "Guides",
      lang_label: "Langue : français", home: "Accueil CyberTrain",
      cmp_caption: "Différences entre Rails et CyberTrain (tableau complet du README)",
    },
  }.freeze
end
