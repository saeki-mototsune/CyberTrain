---
source_sha256: dd0210788bb4d555f4969d357b102d23620f552a33d2a0ef7869ccee0a0bfce0
title: Guides
---
# Guides

Tout ce que la documentation de CyberTrain couvre au-delà de la référence de l’API&nbsp;: le tutoriel qui construit le blog pas à pas, puis un guide pour chaque domaine du framework.

<!-- list: next-list -->
- [**Tutoriel**](tutorial.md) — Construire le blog pas à pas&nbsp;: scaffold, commentaires, authentification, envois de fichiers, déploiement
- [**Installation**](install.md) — Prérequis, la commande `cybertrain`, comment Spinel et le framework sont installés
- [**Fonctionnement**](how-it-works.md) — Génération de code à la compilation, vues interprétées, le serveur, la boucle de développement et la liste complète des différences avec Rails
- [**Modèles et base de données**](models.md) — Migrations, requêtes au-delà de `where`, pagination
- [**Requêtes**](requests.md) — Limitation du débit, l’adresse du client, en-têtes paramétrés, chaînes de requête et corps de requête
- [**Configuration**](configuration.md) — `config/app.rb`, variables d’environnement, fuseaux horaires
- [**Tâches de fond et exploitation**](background-and-operations.md) — Jobs, tâches planifiées, sauvegardes, le contrôle de santé
- [**HTTP sortant, flux WebSocket et e-mail**](external-services.md) — `HttpClient`, `WebSocket.subscribe`, `Mailer`
- [**Tests**](testing.md) — Écrire les tests d’une application, appels sortants, CI
- [**Le langage de templates**](template-language.md) — Les helpers, le constructeur de formulaires et ce qu’un template peut appeler dans `app/views/**/*.html.erb`
