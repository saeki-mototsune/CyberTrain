---
source_sha256: e6c54c45d4c1038441e5ed36184d699152924c52910d1a6cf23f7dc682835874
title: Guides
---
# Guides

Tout ce que la documentation de CyberTrain couvre au-delà de la référence de l’API&nbsp;: le tutoriel qui construit le blog pas à pas, puis un guide pour chaque domaine du framework.

<!-- list: next-list -->
- [**Tutoriel**](tutorial.md) — Construire le blog pas à pas&nbsp;: scaffold, commentaires, mises à jour en direct avec Turbo, un job d’arrière-plan, authentification, envois de fichiers, déploiement
- [**Installation**](install.md) — Prérequis, la commande `cybertrain`, comment Spinel et le framework sont installés
- [**Fonctionnement**](how-it-works.md) — Génération de code à la compilation, vues interprétées, le serveur, la boucle de développement et un tableau des différences avec Rails
- [**Modèles et base de données**](models.md) — Migrations, types de colonnes, requêtes, associations, validations, colonnes chiffrées, transactions, reprise d’une base Rails
- [**Requêtes**](requests.md) — Routage, formats et `respond_to`, concerns, paramètres forts, cache HTTP, cookies et session chiffrée, limitation du débit, Content Security Policy, `force_ssl` et contrôle des hôtes, en-têtes, chaînes de requête et corps de requête
- [**Authentification**](authentication.md) — `generate authentication`&nbsp;: connexion, inscription ou sur invitation, réinitialisation du mot de passe, confirmation, verrouillage, rester connecté, page de compte, administrateurs, mise à jour depuis 0.4
- [**Assets**](assets.md) — Feuilles de style, images et JavaScript avec empreinte, `url()` en CSS, les helpers, l’import map, le service et la conservation
- [**Internationalisation**](i18n.md) — Dictionnaires dans `config/locales`, `t` et `l`, recherche paresseuse, pluriels, choix de la locale par requête, messages de validation traduits, l’anglais et le japonais fournis
- [**Configuration**](configuration.md) — `config/app.rb`, variables d’environnement, fuseaux horaires
- [**Tâches de fond et exploitation**](background-and-operations.md) — Classes de job, nouvelles tentatives, tâches `every` et `cron`, la page des jobs, les rôles de processus `worker` et `feeds`, le cache, la console, sauvegardes, le contrôle de santé, journaux et identifiants de requête, signalement des erreurs à Sentry
- [**Temps réel**](realtime.md) — Turbo Streams sur Server-Sent Events ou WebSocket, diffusions depuis les actions, les jobs et les flux, noms de flux signés, santé des flux
- [**HTTP sortant, flux WebSocket et e-mail**](external-services.md) — `HttpClient` avec flux, gzip et Server-Sent Events, `WebSocket.subscribe` avec minuteries et redémarrages, `Mailer` avec mail HTML et `deliver_later`
- [**Tests**](testing.md) — Écrire les tests d’une application, appels sortants, jobs, journaux et rapports d’erreur, CI
- [**Le langage de templates**](template-language.md) — Les helpers, les composants, le constructeur de formulaires et ce qu’un template peut appeler dans `app/views/**/*.html.erb`
