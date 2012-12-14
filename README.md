PROM (Probabilistic Regulation of Metabolism) Service

This service enables the creation of FBA model objects which include constraints based on regulatory
networks and expression data, as described in [1].  Constraints are constructed by either automatically
aggregating necessary information from the CDS (if available for a given genome), or by adding user
expression and regulatory data.  PROM provides the capability to simulate transcription factor knockout
phenotypes.  PROM model objects are created in a user's workspace, and can be operated on and simulated
with the KBase FBA Modeling Service.

[1] Chandrasekarana S. and Price ND. Probabilistic integrative modeling of genome-scale metabolic and
regulatory networks in Escherichia coli and Mycobacterium tuberculosis. PNAS (2010) 107:17845-50.






dependencies:
erdb_service (deployed clients, and for now, a running local server)
regprecise (deployed clients)
workspace_service (deployed clients)
auth_service (deployed clients)
