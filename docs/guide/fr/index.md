---
source_sha256: 447d7230c2313f3f2c2544e19d67a25e08684ec740ae8e582774f589fce01f08
title: Guides
---
# Guides

Tout ce que la documentation de CyberTrain couvre au-delà de la référence de l’API&nbsp;: le tutoriel qui construit le blog pas à pas, le tutoriel avancé qui le pousse plus loin, puis un guide pour chaque domaine du framework.

<!-- list: next-list -->
- [**Tutoriel**](tutorial.md) — Construire le blog pas à pas&nbsp;: installation, scaffold des articles, validations, commentaires imbriqués sous les articles, tests
- [**Tutoriel avancé**](advanced-tutorial.md) — Pousser le blog plus loin&nbsp;: un composant et un helper, des commentaires en direct avec Turbo, un job d’arrière-plan, JSON, la connexion, une image envoyée, un build pour le déploiement
- [**Installation**](install.md) — Prérequis, la commande `cybertrain`, comment Spinel et le framework sont installés
- [**Fonctionnement**](how-it-works.md) — Génération de code à la compilation, les sous-systèmes optionnels qu’une application charge, vues interprétées, le serveur, SQLite via FFI, la boucle de développement et un tableau des différences avec Rails
- [**Modèles et base de données**](models.md) — Migrations, types de colonnes, requêtes, associations, validations, colonnes chiffrées, transactions, reprise d’une base Rails
- [**Requêtes**](requests.md) — Routage, formats et `respond_to`, concerns, paramètres forts, cache HTTP, cookies et session chiffrée, limitation du débit, Content Security Policy, `force_ssl` et contrôle des hôtes, en-têtes, chaînes de requête et corps de requête
- [**Authentification**](authentication.md) — `generate authentication`&nbsp;: connexion, inscription ou sur invitation, réinitialisation du mot de passe, confirmation, verrouillage, rester connecté, page de compte, administrateurs
- [**Assets**](assets.md) — Feuilles de style, images et JavaScript avec empreinte, `url()` en CSS, les helpers, l’import map, le service et la conservation
- [**Internationalisation**](i18n.md) — Dictionnaires dans `config/locales`, `t` et `l`, recherche paresseuse, pluriels, choix de la locale par requête, messages de validation traduits, l’anglais et le japonais fournis
- [**Configuration**](configuration.md) — `config/app.rb`, variables d’environnement, fuseaux horaires
- [**Tâches de fond et exploitation**](background-and-operations.md) — Classes de job, nouvelles tentatives, tâches `every` et `cron`, la page des jobs, les rôles de processus `worker` et `feeds`, le cache, la console, sauvegardes, le contrôle de santé
- [**Journaux et signalement des erreurs**](logs-and-errors.md) — La ligne de journal, les niveaux et les lignes JSON, identifiants de requête et étiquettes, `Cybertrain.error`, abonnés et filtres, l’envoi à Sentry ou GlitchTip
- [**Temps réel**](realtime.md) — Turbo Streams sur Server-Sent Events ou WebSocket, diffusions depuis les actions, les jobs et les flux, noms de flux signés, santé des flux
- [**HTTP sortant, flux WebSocket et e-mail**](external-services.md) — `HttpClient` avec flux, gzip et Server-Sent Events, `WebSocket.subscribe` avec minuteries et redémarrages, `Mailer` avec mail HTML et `deliver_later`
- [**Tests**](testing.md) — Écrire les tests d’une application, appels sortants, jobs, journaux et rapports d’erreur, CI
- [**Mise à jour**](upgrading.md) — Passer une application à une version plus récente&nbsp;: la procédure, étape par étape avec ses commandes, et les notes de chaque version
- [**Le langage de templates**](template-language.md) — Les helpers, les composants, le constructeur de formulaires et ce qu’un template peut appeler dans `app/views/**/*.html.erb`
