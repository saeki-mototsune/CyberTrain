---
source_sha256: 2fbeb86c43b9789aa21bda936feff3fd39b4035b81a06ea7f92080110e3c4ec3
title: Guides
---
# Guides

Tout ce que la documentation de CyberTrain couvre au-delà de la référence de l’API&nbsp;: le tutoriel qui construit le blog pas à pas, puis un guide pour chaque domaine du framework.

<!-- list: next-list -->
- [**Tutoriel**](tutorial.md) — Construire le blog pas à pas&nbsp;: scaffold, commentaires, authentification, envois de fichiers, déploiement
- [**Installation**](install.md) — Prérequis, la commande `cybertrain`, comment Spinel et le framework sont installés
- [**Fonctionnement**](how-it-works.md) — Génération de code à la compilation, vues interprétées, le serveur, la boucle de développement et un tableau des différences avec Rails
- [**Modèles et base de données**](models.md) — Migrations, types de colonnes, requêtes, associations, validations, colonnes chiffrées, transactions, reprise d’une base Rails
- [**Requêtes**](requests.md) — Limitation du débit, l’adresse du client, en-têtes paramétrés, chaînes de requête et corps de requête
- [**Configuration**](configuration.md) — `config/app.rb`, variables d’environnement, fuseaux horaires
- [**Tâches de fond et exploitation**](background-and-operations.md) — Classes de job, nouvelles tentatives, tâches `every` et `cron`, la page des jobs, les rôles de processus `worker` et `feeds`, le cache, la console, sauvegardes, le contrôle de santé
- [**Temps réel**](realtime.md) — Turbo Streams sur Server-Sent Events ou WebSocket, diffusions depuis les actions, les jobs et les flux, noms de flux signés, santé des flux
- [**HTTP sortant, flux WebSocket et e-mail**](external-services.md) — `HttpClient` avec flux, gzip et Server-Sent Events, `WebSocket.subscribe` avec minuteries et redémarrages, `Mailer` avec mail HTML et `deliver_later`
- [**Tests**](testing.md) — Écrire les tests d’une application, appels sortants, jobs, CI
- [**Le langage de templates**](template-language.md) — Les helpers, les composants, le constructeur de formulaires et ce qu’un template peut appeler dans `app/views/**/*.html.erb`
