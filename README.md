## Car Insurance — Composite Smart Contracts

Trois contrats Solidity représentent les départements du flux métier et un mini Dapp HTML permet de tester via MetaMask.

### Structure
- `contracts/CompositeInsurance.sol` — contrats `claimprocessingDep`, `ClaimsHandlingDep`, `Garage` avec logique de décision.
- `dapp/index.html` — page statique utilisant `ethers.js` pour interagir avec les contrats.

### Déploiement des contrats
1. Compiler les contrats (Remix, Foundry ou Hardhat). Version Solidity 0.8.20.
2. Déployer `ClaimsHandlingDep` en premier (adresse `handling`).
3. Déployer `claimprocessingDep` en second en passant l’adresse de `ClaimsHandlingDep` au constructeur.
4. Sur `ClaimsHandlingDep`, appeler `setProcessingDep(<adresse claimprocessingDep>)`.
5. Déployer `Garage` en passant l’adresse de `ClaimsHandlingDep` (facultatif pour la démo).
6. Alimenter `ClaimsHandlingDep` en ETH (le contrat paye tiers/garage).

### Règles métier codées
- **Third-party** (expert %):  
  - 0–30% → 7 ether au tiers ; 30–70% → 3 ether ; >70% → refus.  
- **All-risk** (damage % garage):  
  - 0–30 → 3 ether ; 30–60 → 6 ether ; 60–80 → 8 ether ; 80–100 → 10 ether ; >100 → refus.
- Les clients doivent être ajoutés et marqués valides avant de déposer une réclamation.
- Les décisions sont renvoyées par `ClaimsHandlingDep` vers `claimprocessingDep` via `decision(...)`.

### Utilisation rapide (Dapp)
1. Ouvrir `dapp/index.html` dans un serveur statique (ex: `npx serve dapp`).
2. Cliquer sur **Connect Wallet**, renseigner les adresses des contrats déployés.
3. En tant qu’admin, appeler `addcustomer`.
4. Soumettre un formulaire `Third_party_car_insurance_form` ou `All_risk_car_insurance_form`.
5. L’admin peut ensuite payer le tiers ou le garage depuis la section « Admin payouts ».

### BPMN (texte synthétique)
- Client: soumet une déclaration, choisit `Third-party` ou `All-risk`.
- Claim Processing: vérifie validité police → enregistre → envoie à Claims Handling.
- Claims Handling: évalue (pourcentage ou damage) → décision positive/négative.
  - Third-party positif: calcule montant et prépare paiement tiers.
  - All-risk positif: autorise garage, évalue coût.
- Garage: reçoit ordre, répare, renvoie reçu.
- Claims Handling: déclenche paiement garage ou tiers.
- Claim Processing: consigne décision et notifie le client (hors chaîne).

### Sécurité / limites
- Aucune authentification forte : le rôle admin est l’adresse qui déploie `ClaimsHandlingDep`/`claimprocessingDep`.
- Paiements simplifiés en ether, pas de garde-fous KYC/AML.
- Notifications / emails sont hors chaîne.

### Tests manuels suggérés
- Ajout client puis dépôt de réclamation incohérente (policy mismatch) → revert attendu.
- Third-party avec 25% → décision positive et payout de 7 ether.
- Third-party avec 80% → décision négative.
- All-risk avec damage=75 → garageCost=8 ether puis paiement garage.

