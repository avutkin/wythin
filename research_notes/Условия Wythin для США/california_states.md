# California and broader US state privacy requirements

Research checked on 2026-11-15. Scope: a roughly 100-person Wythin wellness pilot collecting ECG, RR intervals, accelerometer/body-orientation information, profiles and self-reports; Hetzner hosting, possible coach access and OpenAI-generated metric insights. This is a targeted primary-source assessment, not a completed fifty-state legal opinion. Washington and Nevada are assigned to another researcher.

## Can a mandatory Terms checkbox authorize every health-data use?

### Takeaway

A mandatory affirmative agreement to the app's contract is distinct from legally required sensitive-data consent. A general Terms checkbox plus later opt-out is not a reliable nationwide authorization for optional health-data processing or disclosure.

### Cited Findings

- Colorado's AG says covered controllers need affirmative, freely given, specific and informed consent before sensitive-data processing; acceptance of broad terms does not qualify. General thresholds are 100,000 Colorado consumers, or 25,000 with revenue/discounts from data sales. A small pilot alone does not establish coverage. — [Colorado AG CPA FAQ](https://coag.gov/resources/colorado-privacy-act/)
- Colorado Rules 7.03–7.04 reject blanket terms acceptance, prechecked boxes and negative-option consent. Necessary-service processing is treated differently from making a contract depend on unnecessary processing. Consent requests must be prominent, concise and distinct from other conditions. Rule 7.07 requires comparably easy refusal/revocation. These are binding requirements for covered processing, not an aesthetic preference for extra checkboxes. — [Official Colorado rules, pp. 27–32](https://www.sos.state.co.us/CCR/GenerateRulePdf.do?fileName=4+CCR+904-3&ruleVersionId=10872)
- Connecticut's AG says consumer-health-data controllers doing business in the state or targeting its residents have no revenue or processing threshold. Sensitive data includes consumer health data; processing includes storage and analysis, and requires consent. Employees/contractors must be bound to confidentiality, and health-data processors need written contracts. — [Connecticut AG CTDPA FAQ](https://portal.ct.gov/ag/sections/privacy/the-connecticut-data-privacy-act)
- California CCPA §1798.192 makes contractual waivers or limits on statutory rights unenforceable. Section 1798.100 requires proportionate collection/use/retention and contracts governing disclosures to service providers/contractors and third parties. — [Official CCPA statute effective January 1, 2026](https://cppa.ca.gov/pdf/20260101_ccpa_statute.pdf)

### Inferences

- Implement one required **contract acceptance** if desired, but do not encode that event as universal permission for raw archives, coach disclosure, AI transmission, research or future purposes. Distinct consent can be requested at the point of enabling the corresponding feature; it need not make the initial contract page lengthy. This conclusion follows from the consent distinctions above, not from a claim that every listed statute applies to Wythin today.
- Whether server ECG/RR storage is genuinely necessary to the requested service needs a documented product analysis. Labeling something “required” in Terms does not itself make it necessary. An ordinary local breathing feature does not obviously require optional coach access or AI transmission.
- Existing explicit opt-outs must remain off during a Terms-version migration. A terms revision is not evidence of a new affirmative choice for a separate processing purpose.

### Gaps

- The pilot size is known, but operator-wide revenue, processing totals, corporate affiliations, state targeting and each data recipient's role are not. Consequently most comprehensive-law applicability findings are conditional.
- The current Connecticut statute page repeatedly timed out; this assessment relies on the official AG's current explanatory page, not an independently parsed full current chapter. Do not use a 2023 proposed-bill snippet as proof of final enacted text.

## What California notices and rights are needed?

### Takeaway

An accessible privacy policy is necessary for a commercial online app collecting Californians' identifying information even when CCPA thresholds are not met. A linked Terms document cannot substitute for an accurate privacy notice or required collection-time disclosure.

### Cited Findings

- California AG expressly treats internet-connected mobile apps collecting personal information as online services under CalOPPA and requires reasonably accessible, conspicuously posted policies. A website policy must be linked accessibly from the app. — [AG CalOPPA mobile-app enforcement letter](https://oag.ca.gov/system/files/attachments/press_releases/CalOPPA%20Letter_0.pdf)
- CalOPPA policy content includes collected information and recipient categories, any review/change procedure, material-change notice method, effective date and applicable cross-site-tracking/Do Not Track disclosures. The AG guide distinguishes legal requirements from its recommended clarity/accessibility practices. — [AG privacy-policy guide, statutory appendix and recommendations](https://oag.ca.gov/sites/all/files/agweb/pdfs/cybersecurity/making_your_privacy_practices_public.pdf)
- CCPA business coverage can arise from annual gross revenue above $26,625,000, buying/selling/sharing data of at least 100,000 consumers/households, or at least half of revenue from selling/sharing personal information; other statutory business relationships can matter. Thus “100 users” is not itself a complete coverage determination. — [CPPA applicability checklist](https://cppa.ca.gov/pdf/business_comply.pdf), [official monetary adjustment effective January 1, 2025](https://cppa.ca.gov/announcements/2024/20241217.html)
- For covered businesses, CCPA §1798.100 requires collection-time disclosure of data categories, purposes, sensitive categories and retention period/criteria. Sections 1798.105–.125 establish deletion, correction, access, opt-out/limitation and non-discrimination rights, with statutory exceptions. — [Official 2026 CCPA statute](https://cppa.ca.gov/pdf/20260101_ccpa_statute.pdf)
- Regulations §7012 require notice before collection. A link to a policy must land directly at the relevant collection-notice section; forcing people to search a long document is insufficient. The notice covers categories, purposes, sale/sharing status and retention. Section 7011 also requires an app Settings privacy-policy link. These requirements are separate from whether a contract checkbox is valid. — [CCPA regulations effective January 1, 2026, §§7011–7012](https://cppa.ca.gov/regulations/pdf/ccpa_statute_eff_20260101.pdf)

### Inferences

- Keep distinct conspicuous links labeled **Terms & Conditions**, **Privacy Policy**, and, when necessary, **Consumer Health Data Privacy Policy**. The collection explanation should use a direct anchor, not merely “details in Terms.” A layered short notice may link to comprehensive details.
- The policy should map ECG, RR, motion/orientation, timestamps/device identifiers, calculated metrics, self-reports and contact data to each purpose, recipient and retention rule. Explicitly distinguish orientation from GPS. Do not characterize linked/pseudonymous ECG or numerical metrics as anonymous merely because names were removed.
- Wythin should offer an operational rights-request route even before comprehensive-law thresholds apply. State rights language should say when statutory rights apply, rather than falsely asserting universal statutory coverage.
- Avoid a generic “no sharing” claim when coaches, hosting vendors or AI providers receive data. Define any narrower no-sale/no-cross-context-advertising statement accurately and separately from ordinary disclosure.

### Gaps

- We do not yet know the legal operator, business mailing address, final minimum age, retention schedule or complete subprocessors. Do not invent them or publish a final policy implying they are settled.
- The official CalOPPA statute endpoint returned 403; its content was cross-checked through the AG's official guidance and enforcement letter. The recommendations PDF dates from 2014; current CCPA obligations were separately checked against the agency's 2026 statute and regulations.

## Which stricter state baselines affect a US launch?

### Takeaway

Use a sensitive-data opt-in, minimization and enforceable-revocation baseline instead of assuming California's rules are the whole US standard. State laws differ in scope, necessary-service rules, deadlines, exemptions and age provisions.

### Cited Findings

- Maryland MODPA took effect October 1, 2025. Its general thresholds are 35,000 Maryland consumers or 10,000 plus over 20% of revenue from data sales. Where applicable, sensitive data may not be sold and may only be collected, processed or shared when strictly necessary for the specific service requested. Controllers need notices, safeguards, rights handling and risk assessments. A general multi-state rights section is permitted if Marylanders' rights are unambiguous. — [Maryland AG MODPA FAQ](https://oag.maryland.gov/Resources-Info/Pages/data-privacy.aspx)
- Oregon generally applies at 100,000 consumers or 25,000 plus over 25% of revenue from sales. Covered controllers need consent for collecting, storing or otherwise processing sensitive data and for incompatible secondary purposes. Health-status data is sensitive; processor obligations and written contracts apply. — [Oregon DOJ business FAQ](https://www.doj.state.or.us/consumer-protection/for-businesses/privacy-law-faqs-for-businesses/), [ORS 646A.570–.589](https://www.oregonlegislature.gov/bills_laws/ors/ors646A.html)
- Texas generally exempts SBA-defined small businesses, but even an otherwise exempt small business must obtain prior consent before selling sensitive personal data. For covered controllers, processing sensitive data requires consent. Therefore “under 100 users” is not a substitute for assessing the actual exemption and data transactions. — [Texas AG TDPSA guidance](https://www.texasattorneygeneral.gov/consumer-protection/file-consumer-complaint/consumer-privacy-rights/texas-data-privacy-and-security-act)
- Connecticut also protects minors under 18 in relevant online services. Its AG describes access/correction/deletion/portability rights, a 45-day response period subject to extension, and appeal handling; health-data-controller coverage has no ordinary size threshold. — [Connecticut AG CTDPA FAQ](https://portal.ct.gov/ag/sections/privacy/the-connecticut-data-privacy-act)

### Inferences

- At 100 users, Maryland/Colorado/Oregon numerical thresholds may not be reached by this pilot, but that does not establish exemption from all state health/privacy laws. Broader operator activity and threshold-free health statutes matter.
- For the first release, adults-only eligibility is a reasonable design option to reduce children's-data complexity, but an “18+” clause alone does not resolve actual knowledge of underage use. User confirmation of intended audience is needed; do not silently rewrite eligibility.
- A single Terms acceptance may gate the contract, while necessary sensor processing receives a specific consent request and nonessential AI/coaching gets independent opt-in. Declining an optional purpose should only disable that feature. This is a recommended cross-state implementation baseline, not a legal conclusion that every feature is optional in every product configuration.
- Raw-data retention, archived summaries and “effect traces” remain personal/health data if linkable to a user. Compression or aggregation does not by itself eliminate deletion, purpose-limitation or security duties.

### Gaps

- This research does not certify coverage of every state enactment, 2026 amendment or future effective date. A launch matrix must inventory actual states served, applicable thresholds/exemptions, security/breach laws and consumer-health statutes.
- No vendor agreements were reviewed. Hetzner or OpenAI cannot simply be labeled a processor in the app text without contractual and operational restrictions supporting that role.

## Is avoiding medical claims or HIPAA enough in California?

### Takeaway

No. California medical-information law can independently reach some consumer health apps. Wythin's exact CMIA status requires a feature/data-source assessment rather than an automatic “not HIPAA” exclusion.

### Cited Findings

- California AG's Glow enforcement involved a consumer fertility app, identified CMIA and basic security failures, and required improved safeguards and affirmative revocable sharing permission. That is evidence of potential health-app regulation outside ordinary clinical HIPAA relationships, not a ruling about all wellness apps. — [AG privacy enforcement actions, Glow section](https://oag.ca.gov/privacy/privacy-enforcement-actions)
- The California Supreme Court resolved *J.M. v. Illuminate Education*, S286699, on May 14, 2026; the official docket shows the case closed. It concerns CMIA coverage and data security. The lower-court interpretation or 2025 advocacy briefs should not be treated as the current final rule without reading the Supreme Court opinion. — [Official Supreme Court docket](https://appellatecases.courtinfo.ca.gov/search/case/dockets.cfm?dist=0&doc_id=3110407&doc_no=S286699), [official May 14, 2026 minutes](https://supreme.courts.ca.gov/sites/default/files/supremecourt/default/documents/m05142026%28th%29%20-%20R.pdf)

### Inferences

- Keep “wellness, not diagnosis” statements accurate, but do not use them as a blanket waiver of medical-data obligations. Wythin's proposed mood, attention and nervous-system analyses increase the importance of this classification review.
- Any contractual promise that access is restricted, users can withdraw sharing, or deletion reaches backups must be verified in the implementation. Legal drafting cannot repair weak user authentication, unrestricted administrator access or unenforced Settings switches.

### Gaps

- The current Supreme Court full opinion could not be retrieved from the official opinions listing (403); no substantive holding from a secondary summary is adopted here. Counsel should review the current §56.06/§56.11 framework and final opinion against Wythin's exact app functions before asserting CMIA inclusion or exclusion.
- Operator identity, security implementation, vendor agreements and actual rights/withdrawal procedures remain launch verification tasks. These notes provide requirements and uncertainties, not a guarantee of US-wide legality.
