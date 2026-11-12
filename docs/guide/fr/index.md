---
source_sha256: 326214473484c7dca6fd6dcd67e2506aaf44eb88422bf9f319d42b6343efc5d8
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
- [**Assets**](assets.md) — Feuilles de style, images et JavaScript avec empreinte, `url()` en CSS, les helpers, l’import map, le service et la conservation
- [**Configuration**](configuration.md) — `config/app.rb`, variables d’environnement, fuseaux horaires
- [**Tâches de fond et exploitation**](background-and-operations.md) — Classes de job, nouvelles tentatives, tâches `every` et `cron`, la page des jobs, les rôles de processus `worker` et `feeds`, le cache, la console, sauvegardes, le contrôle de santé
- [**Temps réel**](realtime.md) — Turbo Streams sur Server-Sent Events ou WebSocket, diffusions depuis les actions, les jobs et les flux, noms de flux signés, santé des flux
- [**HTTP sortant, flux WebSocket et e-mail**](external-services.md) — `HttpClient` avec flux, gzip et Server-Sent Events, `WebSocket.subscribe` avec minuteries et redémarrages, `Mailer` avec mail HTML et `deliver_later`
- [**Tests**](testing.md) — Écrire les tests d’une application, appels sortants, jobs, CI
- [**Le langage de templates**](template-language.md) — Les helpers, les composants, le constructeur de formulaires et ce qu’un template peut appeler dans `app/views/**/*.html.erb`
