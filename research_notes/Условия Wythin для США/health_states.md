# Consumer health privacy in Washington, Nevada, Connecticut and Maryland

Research date: 2026-11-15. Primary-source implementation notes, not an opinion certifying nationwide compliance. Wythin product facts were provided by the coordinator; no production records were accessed. This research covers the particularly relevant health-data regimes, not all fifty states.

## Can one mandatory Terms checkbox authorize every health-data operation in Washington?

### Takeaway

No: Washington expressly excludes broad Terms acceptance from its definition of health-data consent. Necessary processing for a service the consumer actually requested can qualify for a statutory exception; a declaration in Terms that everything is mandatory does not establish that factual necessity. [RCW 19.373.010(6)](https://app.leg.wa.gov/rcw/default.aspx?cite=19.373.010), [RCW 19.373.030](https://app.leg.wa.gov/rcw/default.aspx?cite=19.373.030).

### Cited Findings

- Consent must be affirmative, voluntary, informed and specific. General Terms containing unrelated information do not qualify. Health data encompasses identifiable vital signs and inferred physical or mental health. Washington residents and people whose data is collected there are covered; the law also regulates small businesses. Processor disclosures serving the disclosed collection purpose can fall outside statutory sharing. The definition of an app homepage includes its platform/download page and an in-app link. [RCW 19.373.010](https://app.leg.wa.gov/rcw/default.aspx?cite=19.373.010).
- Collection needs purpose-specific consent unless necessary for a requested service. Sharing needs distinct consent from collection unless necessary for that service. When consent is required, obtain it before collection/sharing and conspicuously disclose categories, purpose, recipient categories and withdrawal mechanism. Unlawful discrimination for exercising rights is prohibited. Small-business compliance started June 30, 2024. [RCW 19.373.030](https://app.leg.wa.gov/rcw/default.aspx?cite=19.373.030).
- The health privacy policy must disclose data categories, uses, source categories, sharing categories, recipient categories/specific affiliates and rights procedures. Publish a prominent homepage link. Disclosing a new data category and obtaining affirmative consent must precede using it. [RCW 19.373.020](https://app.leg.wa.gov/rcw/default.aspx?cite=19.373.020).
- The Attorney General interprets the required Consumer Health Data Privacy Policy link as separate and distinct; the policy must not contain extraneous material. A Terms-only link is therefore insufficient. This FAQ was retrieved through the search index; direct open returned 403. [Washington AG FAQ, question 4](https://www.atg.wa.gov/protecting-washingtonians-personal-health-data-and-privacy).
- Rights include access, a recipient list/contact mechanisms, withdrawal and deletion. Deletion reaches recipients and backups; restoration-related backup delay is capped at six months after authentication. Respond within 45 days of receipt; one justified additional 45-day extension requires notice. Authentication does not restart that response deadline. Provide a conspicuous appeal process; respond to appeals within 45 days and supply an AG complaint mechanism on denial. Requests need secure authentication, without requiring a new account. [RCW 19.373.040](https://app.leg.wa.gov/rcw/default.aspx?cite=19.373.040).
- Staff, contractors and processors should have access only where necessary for the consented purpose or requested service. Actual administrative, technical and physical safeguards must meet reasonable industry care; a policy statement is not a substitute. [RCW 19.373.050](https://app.leg.wa.gov/rcw/default.aspx?cite=19.373.050).
- Processor contracts must bind processing instructions and limits; processors must assist compliance. Acting beyond instructions can make a processor independently regulated for that processing. [RCW 19.373.060](https://app.leg.wa.gov/rcw/default.aspx?cite=19.373.060).

### Inferences

- Implement one mandatory **contract acceptance** if desired, but do not make that action mutate optional health permissions to true. A separate, purpose-specific health-data action or properly substantiated requested-service exception is needed. Turning everything on and permitting later withdrawal does not solve absent prior consent. This follows from the separate-consent structure above.
- A functional design can present the mandatory contract and readable links first; request optional raw archiving, coaching access or AI processing at the relevant feature, before sending data. Preserve historical denials and document which mandatory processing is technically necessary for the requested feature.
- Hosting on Hetzner is not automatically third-party sharing in Washington if it is genuinely processing on Wythin's behalf under appropriate instructions; independent coaching or AI secondary use cannot simply be labelled a processor to obtain that result. Obtain and review actual provider agreements.
- RR/ECG are health data regardless of whether they are used as biometric identifiers. Describe accelerometer-derived body orientation separately from geographic location; the two are not interchangeable.
- For a national deletion implementation, six-month-or-shorter backup erasure is a stricter design ceiling than Nevada's allowance below; a shorter practical retention should be selected and tested.

### Gaps

- The necessity of 24/7 raw retention, coaching and external AI has not been established. The user explicitly values future analytical flexibility, which is a distinct purpose needing assessment rather than assumed necessity for today's feature.
- Processor contracts, provider training/retention, team access controls, identity verification, the recipient ledger and backup erasure have not been audited by this researcher. No claim that existing implementation satisfies the statutes is made.
- Eligibility for statutory exemptions requires actual business/healthcare facts; do not assume a wellness label or a small pilot is exempt.

## What changes for Nevada?

### Takeaway

Nevada likewise distinguishes collection from sharing consent and recognizes requested-service necessity. [NRS 603A.500](https://www.leg.state.nv.us/nrs/NRS-603A.html#NRS603ASec500).

### Cited Findings

- Affirmative voluntary collection consent and separate sharing consent must precede processing unless a statutory exception applies. Requests disclose categories, purpose, recipients and withdrawal. Unlike Washington, the current sharing definition has no general processor carve-out. The final codification does not reproduce an earlier bill draft's broad-Terms exclusion. [NRS 603A.480–.500](https://www.leg.state.nv.us/nrs/NRS-603A.html#NRS603ASec480).
- A conspicuous health-policy link or equivalent notice is required. Rights cover confirmation, recipient list, cessation and deletion. General responses: 45 days after authentication, with one justified 45-day extension. Deletion: 30 days after authentication; notify recipients, who have 30 days after notice. Necessary backup-restoration delay: at most two years. Appeals: 45 days. [NRS 603A.495–.520](https://www.leg.state.nv.us/nrs/NRS-603A.html#NRS603ASec495).
- Purpose-limited access, security practices and processor instructions/contracts are required. Rights-based discrimination is prohibited. Sale requires written authorization and cannot be a condition of services. [NRS 603A.525–.545](https://www.leg.state.nv.us/nrs/NRS-603A.html#NRS603ASec525).

### Inferences

- Use the stronger Washington consent separation nationally rather than treating a provider's processor status as sufficient everywhere.

### Gaps

- Actual exemptions and necessity remain fact-dependent; final Nevada statutory text takes precedence over old SB370 drafts.

## What additional state rules materially affect a small wellness app?

### Takeaway

Connecticut's 2026 sensitive-data scope means a small pilot is not automatically exempt. Maryland additionally restricts unnecessary sensitive-data processing even where consent is offered, if its business thresholds are met. [CT 2026 supplement, §§42-516, 42-520](https://prdext3.cga.ct.gov/2026/sup/chap_743jj.htm), [Maryland §14-4707](https://mgaleg.maryland.gov/mgawebsite/Laws/StatuteText?article=gcl&section=14-4707).

### Cited Findings

- Effective July 1, 2026, Connecticut's scope includes processing sensitive consumer data separately from the 35,000-consumer volume route. Sensitive data includes health data. Broad Terms acceptance is excluded from consent. Sensitive processing requires consent and reasonable necessity; withdrawal must be as easy as consent and processing must stop as soon as practicable, at most 15 days after withdrawal. Applicable sensitive processing also requires a data-protection assessment. [CT 2026 supplement, §§42-515, 42-516, 42-520, 42-522](https://prdext3.cga.ct.gov/2026/sup/chap_743jj.htm).
- Connecticut's health-specific duties require confidentiality obligations for employees/contractors and compliant processor agreements. Those provisions are not conditioned on the ordinary volume threshold. [CT §42-526](https://prdext3.cga.ct.gov/current/pub/chap_743jj.htm#sec_42-526).
- October 1, 2026 amendments further remove the word “material” from the new-purpose consent requirement. The official enacted-act search excerpt supports that change; direct PDF opens failed (502/inaccessible), so verify the full act before relying on detailed October amendment language. The retained sensitive-data consent/necessity rule is independently visible in the 2026 supplement. [P.A. 26-64 §14](https://www.cga.ct.gov/2026/ACT/PA/PDF/2026PA-00064-R00SB-00004-PA.PDF).
- Maryland applies where an in-state/targeting business processed at least 35,000 consumers in the prior year, or 10,000 with more than 20% revenue from personal-data sales; payment-only processing is excluded from the first threshold. [Maryland §14-4702](https://mgaleg.maryland.gov/mgawebsite/Laws/StatuteText?article=gcl&section=14-4702).
- Maryland limits sensitive processing/sharing to what is strictly necessary to supply or maintain the specific requested service and prohibits selling sensitive data. It requires minimization, reasonable security and easy withdrawal, with cessation within 30 days. It does not require providing a data-dependent service when the requisite data are unavailable; that exception is not blanket permission to demand unrelated processing. [Maryland §14-4707](https://mgaleg.maryland.gov/mgawebsite/Laws/StatuteText?article=gcl&section=14-4707).
- Maryland excludes broad Terms from consent; health data includes data used to identify physical or mental health status. Its current code numbering is 14-4701 onward, rather than the earlier bill's 14-4601 numbering. [Maryland §14-4701](https://mgaleg.maryland.gov/mgawebsite/Laws/StatuteText?article=gcl&section=14-4701).

### Inferences

- Do not ship a national “all processing enabled by general Terms” claim. Terms, health notices, purpose-specific controls, contracts, deletion/appeals and operational safeguards must be consistent.
- State choice should not be inferred from phone timezone. A robust national permission baseline avoids relying on an unverified state guess and preserves rights when people travel.
- Provide a requested-service necessity inventory: data field, feature, purpose, retention, recipient, rationale and applicable permission. Future research/model development must not silently inherit the purpose of calculating today's HRV.

### Gaps

- This targeted review is not a fifty-state inventory. Other comprehensive privacy, biometric, child privacy, breach, professional/medical confidentiality and contractual rules require separate applicability review.
- No legal entity/address, exact users' residency, minor eligibility, vendor contracts, or necessary-service determination was supplied to this researcher. Counsel should review the final flow and those facts before a nationwide compliance claim.
