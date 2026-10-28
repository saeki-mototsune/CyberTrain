---
source_sha256: 71340fc14e1e2135afadccd8376fd9523bf610df53ed4fff573f49625f19cc4f
title: Guides
---
# Guides

Tout ce que la documentation de CyberTrain couvre au-delà de la référence de l’API&nbsp;: le tutoriel qui construit le blog pas à pas, puis un guide pour chaque domaine du framework.

<!-- list: next-list -->
- [**Tutoriel**](tutorial.md) — Construire le blog pas à pas&nbsp;: scaffold, commentaires, authentification, envois de fichiers, déploiement
- [**Installation**](install.md) — Prérequis, le bac à sable, toutes les commandes `cybertrain`, comment Spinel est installé
- [**Fonctionnement**](how-it-works.md) — Génération de code à la compilation, différences avec Rails, performances
- [**Modèles et base de données**](models.md) — Migrations, requêtes au-delà de `where`, pagination
- [**Requêtes**](requests.md) — Limitation du débit, l’adresse du client, en-têtes paramétrés
- [**Configuration**](configuration.md) — `config/app.rb`, variables d’environnement, fuseaux horaires
- [**Tâches de fond et exploitation**](background-and-operations.md) — Jobs, tâches planifiées, sauvegardes, le contrôle de santé
- [**HTTP sortant, flux WebSocket et e-mail**](external-services.md) — `HttpClient`, `WebSocket.subscribe`, `Mailer`
- [**Tests**](testing.md) — Écrire les tests d’une application, appels sortants, CI
- [**Le langage de templates**](template-language.md) — Les helpers, le constructeur de formulaires et ce qu’un template peut appeler dans `app/views/**/*.html.erb`
