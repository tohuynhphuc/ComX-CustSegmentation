# Nine-chapter restructuring guide

This version reorganizes the earlier revised LaTeX report while retaining the technical content and style of the team's original draft where supportable.

## Chapter map
1. Introduction — revised background and objectives.
2. Background and Related Applications — revised sources and concepts.
3. Data Warehouse Design — preserved and corrected original schema explanation.
4. ETL Pipeline and Automation — preserved original SSIS queries, figures, procedures, scheduling explanations.
5. RFM Analysis and K-Means Clustering — preserved the worked tables, model explanation and diagnostic plots.
6. Business Intelligence and Analytics Dashboards — preserved the three-page Power BI walkthrough and DAX table.
7. Business Insights and Decision-Making — moved existing five segment recommendations and the existing decision-support use case from the old Chapter 6; added a short transition.
8. System Integration, Verification and Limitations — new concise chapter summarizing the actual dependencies, testable checks, and remaining integration limitations, not a separate experiments chapter.
9. Conclusion and Future Work — largely retained the previous conclusion.

## Notes to the team
- Fill the contribution percentages at the front.
- Reconcile the 18,484 versus 18,485 customer counts.
- Confirm dashboard figures and final Page 1 measures if further edits are made.
- The annual Airflow DAG is configured but its fully unattended, snapshot-dependent run has not been verified; do not claim otherwise.
- No new images are required. Existing figures and ML diagnostics have been retained.
- The file VERIFY_BUSINESS_FIGURES.sql includes read-only SQL checks for introductory business numbers.
- Edit chapter files individually under sections/section1.tex through sections/section9.tex.

## Compiling
From the project directory, run `latexmk -pdf main.tex` (requires a TeX installation including biber). The compiled PDF was checked for unresolved references and LaTeX compilation errors.
