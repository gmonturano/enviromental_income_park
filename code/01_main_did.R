# Protected areas and income in Italian inner municipalities
# Main two-way fixed-effects DiD specifications, metadata-driven.

required_packages <- c("plm", "readxl")
missing_packages <- setdiff(required_packages, rownames(installed.packages()))
if (length(missing_packages)) {
  stop("Install required R packages: ", paste(missing_packages, collapse = ", "))
}

root_data <- file.path("db", "db_TOT_aree_prot.RData")
meta_path <- file.path("code", "meta_DB_Turi_spec_2007_2020.xlsx")
stopifnot(file.exists(root_data), file.exists(meta_path))

data_env <- new.env(parent = emptyenv())
loaded <- load(root_data, envir = data_env)
if (!"DB_finale" %in% loaded) {
  stop("The RData input must contain the original 'DB_finale' object.")
}
db <- as.data.frame(data_env$DB_finale)

# Reproduce the variable transformations in the authors' benchmark script.
required_raw <- c("COD_COM", "Anno", "Redditi_Procapite", "X..Aree.protette")
missing_raw <- setdiff(required_raw, names(db))
if (length(missing_raw)) stop("Missing required columns: ", paste(missing_raw, collapse = ", "))

safe_log <- function(x) {
  x <- suppressWarnings(as.numeric(as.character(x)))
  out <- log(x)
  out[!is.finite(out)] <- NA_real_
  out
}

# The original main script defines protected-area exposure as a share (0 to 1)
# and applies log transformations to the outcome and pillar variables.
db$X..Aree.protette <- suppressWarnings(as.numeric(as.character(db$X..Aree.protette))) / 100
db$Redditi_Procapite <- safe_log(db$Redditi_Procapite)
for (var in c("Reddito.imponibile...Ammontare.in.euro", "Popolazione.fine.periodo",
              "Pillar1_bur", "Pillar2_pol", "Pillar3_econ")) {
  if (var %in% names(db)) db[[var]] <- safe_log(db[[var]])
}

# Hotel and non-hotel tourism beds per km2 (original benchmark definitions).
if (all(c("Totale Alberghi_pl", "Superficie.comunale..kmq.") %in% names(db))) {
  db$Totale.Alberghi_pl_pro_sup <- pmax(
    0, as.numeric(db[["Totale Alberghi_pl"]]) /
      as.numeric(db$Superficie.comunale..kmq.))
}
if (all(c("Totale esercizi extra-alberghieri_pl", "Superficie.comunale..kmq.") %in% names(db))) {
  db$Totale.esercizi.extra_alberghieri_pl_sup <- pmax(
    0, as.numeric(db[["Totale esercizi extra-alberghieri_pl"]]) /
      as.numeric(db$Superficie.comunale..kmq.))
}

# The original analysis sets missing frequency controls to zero.
frequency_controls <- grep("_freq$", names(db), value = TRUE)
for (var in frequency_controls) {
  x <- suppressWarnings(as.numeric(as.character(db[[var]])))
  x[is.na(x)] <- 0
  db[[var]] <- x
}
if ("Finanziamenti_tot_SNAI" %in% names(db)) {
  db$Finanziamenti_tot_SNAI[is.na(db$Finanziamenti_tot_SNAI)] <- 0
}

# Treatment period and dose are read from the processed panel as in the source.
# This script does not synthesize or overwrite the study's treatment indicator.
if (!"Treat" %in% names(db)) stop("The processed panel must contain 'Treat'.")

metadata <- as.data.frame(readxl::read_xlsx(meta_path, sheet = 1))
if (!"names.Panel." %in% names(metadata)) stop("Missing metadata field 'names.Panel.'.")
specifications <- grep("^Spec", names(metadata), value = TRUE)
if (!length(specifications)) stop("No main specifications in metadata.")

# Keep the first record when original input contains duplicate municipality-years.
db <- db[!duplicated(db[c("COD_COM", "Anno")]), , drop = FALSE]
db <- db[order(db$COD_COM, db$Anno), , drop = FALSE]
panel <- plm::pdata.frame(db, index = c("COD_COM", "Anno"))

main_models <- list()
for (spec in specifications) {
  get_vars <- function(label) {
    x <- metadata$names.Panel.[metadata[[spec]] == label]
    unique(stats::na.omit(trimws(as.character(x))))
  }
  dependent <- get_vars("dependent_var")
  regressors <- unique(c(get_vars("independent_vars"), get_vars("interaction"), get_vars("control_vars")))
  if (length(dependent) != 1L || !length(regressors)) {
    stop("Incomplete dependent variable or regressors in ", spec)
  }
  model_formula <- stats::reformulate(regressors, response = dependent)
  vars_needed <- all.vars(model_formula)
  missing_vars <- setdiff(vars_needed, names(panel))
  if (length(missing_vars)) {
    stop("Missing variables in ", spec, ": ", paste(missing_vars, collapse = ", "))
  }
  main_models[[spec]] <- plm::plm(
    formula = model_formula,
    data = panel,
    model = "within",
    effect = "twoways"
  )
}

# Save model objects and a transparent coefficient table; do not redistribute
# these outputs as the published coefficients without verifying the data version.
dir.create(file.path("results", "tables"), recursive = TRUE, showWarnings = FALSE)
saveRDS(main_models, file.path("results", "tables", "main_models.rds"))
coef_tables <- do.call(rbind, lapply(names(main_models), function(spec) {
  sm <- summary(main_models[[spec]])
  tab <- as.data.frame(sm$coefficients)
  data.frame(specification = spec, term = rownames(tab), tab,
             row.names = NULL, check.names = FALSE)
}))
utils::write.csv(coef_tables, file.path("results", "tables", "main_coefficients.csv"), row.names = FALSE)
print(coef_tables)
