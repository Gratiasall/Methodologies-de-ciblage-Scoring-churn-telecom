# =========================================================
# Projet : Scoring churn télécom - V2 orientée performance
# =========================================================

# ---------------------------------------------------------
# 0. REPRODUCTIBILITÉ ET PACKAGES
# ---------------------------------------------------------
set.seed(1998)
options(scipen = 999)

library(conflicted)

# Manipulation / visualisation
library(tidyverse)
library(lubridate)
library(janitor)

install.packages("workflowsets")

# Préparation / modélisation
library(rsample)
library(recipes)
library(parsnip)
library(workflows)
library(workflowsets)
library(yardstick)
library(tune)
library(dials)
library(vip)
library(themis)

# Modèles
library(glmnet)
library(ranger)
library(xgboost)
library(kernlab)

# Aides
library(pROC)
library(broom)

conflict_prefer("select", "dplyr")
conflict_prefer("filter", "dplyr")
conflict_prefer("rename", "dplyr")
conflict_prefer("slice", "dplyr")
conflict_prefer("arrange", "dplyr")
conflict_prefer("mutate", "dplyr")
conflict_prefer("step", "recipes")

# ---------------------------------------------------------
# 1. IMPORTATION DES DONNÉES
# ---------------------------------------------------------
base_2024 <- read.table(
  file = "base_telecom_2024_12.txt",
  fileEncoding = "UTF-8",
  sep = ";",
  header = TRUE,
  na.strings = ""
)

base_2025 <- read.table(
  file = "base_telecom_2025_03.txt",
  fileEncoding = "UTF-8",
  sep = ";",
  header = TRUE,
  na.strings = ""
)

# ---------------------------------------------------------
# 2. NORMALISATION DES TYPES
# ---------------------------------------------------------
var_id <- "id_client"
var_geo <- "code_postal"

var_dates <- names(base_2025)[grepl("^date", names(base_2025))]

var_ql_2025 <- base_2025 %>%
  select(where(is.character), starts_with("flag"),
         -starts_with("date"), -all_of(var_id), -all_of(var_geo)) %>%
  names()

var_ql_2024 <- c(var_ql_2025, "flag_resiliation")

base_2024 <- base_2024 %>%
  mutate(
    across(all_of(var_dates), ~ as.Date(.x, format = "%d/%m/%Y")),
    across(all_of(var_ql_2024), as.factor),
    across(c(all_of(var_id), all_of(var_geo)), as.character),
    across(where(is.integer), as.numeric)
  ) %>%
  clean_names()

base_2025 <- base_2025 %>%
  mutate(
    across(all_of(var_dates), ~ as.Date(.x, format = "%d/%m/%Y")),
    across(all_of(var_ql_2025), as.factor),
    across(c(all_of(var_id), all_of(var_geo)), as.character),
    across(where(is.integer), as.numeric)
  ) %>%
  clean_names()

# ---------------------------------------------------------
# 3. DATES DE RÉFÉRENCE
# ---------------------------------------------------------
date_ref_2024 <- as.Date("2024-12-31")
date_ref_2025 <- as.Date("2025-03-31")

# ---------------------------------------------------------
# 4. POPULATION ÉLIGIBLE
# ---------------------------------------------------------
apply_eligibility <- function(df, date_ref) {
  df %>%
    mutate(
      age = floor(time_length(interval(date_naissance, date_ref), "years")),
      anciennete_mois_brut = time_length(interval(date_activation, date_ref), "months"),
      
      exclu_trop_recent = ifelse(
        !is.na(anciennete_mois_brut) & anciennete_mois_brut < 3, 1, 0
      ),
      exclu_date_activation_future = ifelse(
        !is.na(date_activation) & date_activation > date_ref, 1, 0
      ),
      exclu_fin_engagement_avant_activation = ifelse(
        !is.na(date_fin_engagement) & !is.na(date_activation) &
          date_fin_engagement < date_activation, 1, 0
      ),
      exclu_reengagement_avant_activation = ifelse(
        !is.na(date_dernier_reengagement) & !is.na(date_activation) &
          date_dernier_reengagement < date_activation, 1, 0
      )
    ) %>%
    filter(
      exclu_trop_recent == 0,
      exclu_date_activation_future == 0,
      exclu_fin_engagement_avant_activation == 0,
      exclu_reengagement_avant_activation == 0,
      is.na(age) | age < 80
    )
}

base_2024_elig <- apply_eligibility(base_2024, date_ref_2024)
base_2025_elig <- apply_eligibility(base_2025, date_ref_2025)

# Diagnostic cible
diag_target <- base_2024_elig %>%
  count(flag_resiliation) %>%
  mutate(freq = n / sum(n))

print(diag_target)

# ---------------------------------------------------------
# 5. FEATURE ENGINEERING AVANT SPLIT
#    (uniquement transformations déterministes et métier)
# ---------------------------------------------------------
feature_engineering <- function(df, date_ref) {
  df %>%
    mutate(
      # --- standardisation texte offres
      duree_offre_initiale = as.factor(trimws(as.character(duree_offre_initiale))),
      duree_offre_actuelle = as.factor(trimws(as.character(duree_offre_actuelle))),
      duree_offre_initiale_txt = trimws(as.character(duree_offre_initiale)),
      duree_offre_actuelle_txt = trimws(as.character(duree_offre_actuelle)),
      
      # --- offre illimitée
      offre_init_illimitee = ifelse(str_to_lower(duree_offre_initiale_txt) == "illimité", 1, 0),
      offre_actu_illimitee = ifelse(str_to_lower(duree_offre_actuelle_txt) == "illimité", 1, 0),
      
      # --- extraction heures
      duree_offre_initiale_h = as.numeric(str_extract(duree_offre_initiale_txt, "\\d+")),
      duree_offre_actuelle_h = as.numeric(str_extract(duree_offre_actuelle_txt, "\\d+")),
      
      # --- âges / durées
      age = floor(time_length(interval(date_naissance, date_ref), "years")),
      anciennete_mois = round(time_length(interval(date_activation, date_ref), "months"), 2),
      mois_fin_engagement = round(time_length(interval(date_ref, date_fin_engagement), "months"), 2),
      duree_dernier_reengagement = round(time_length(interval(date_dernier_reengagement, date_ref), "months"), 2),
      
      # --- imputation métier de date_fin_engagement
      date_fin_engagement = case_when(
        !is.na(date_fin_engagement) ~ date_fin_engagement,
        is.na(date_fin_engagement) & nb_reengagements == 0 ~ date_activation %m+% years(1),
        is.na(date_fin_engagement) & nb_reengagements != 0 ~ date_dernier_reengagement %m+% years(1),
        TRUE ~ as.Date(NA)
      ),
      
      # --- indicateur de réengagement
      flag_reengagement = factor(ifelse(!is.na(date_dernier_reengagement), 1, 0), levels = c(0, 1)),
      
      # --- imputation métier nb_sms_m2
      nb_sms_m2 = case_when(
        !is.na(nb_sms_m2) ~ nb_sms_m2,
        is.na(nb_sms_m2) & !is.na(nb_sms_m1) & !is.na(nb_sms_m3) ~ (nb_sms_m1 + nb_sms_m3) / 2,
        is.na(nb_sms_m2) & !is.na(nb_sms_m1) & is.na(nb_sms_m3) ~ nb_sms_m1,
        is.na(nb_sms_m2) & is.na(nb_sms_m1) & !is.na(nb_sms_m3) ~ nb_sms_m3,
        TRUE ~ NA_real_
      ),
      
      # --- évolutions relatives
      evol_appels_13 = (vol_appels_m1 - vol_appels_m3) / (vol_appels_m3 + 1),
      evol_sms_13    = (nb_sms_m1 - nb_sms_m3) / (nb_sms_m3 + 1),
      evol_data_13   = (vol_data_m1 - vol_data_m3) / (vol_data_m3 + 1),
      
      # --- ratios relatifs
      ratio_appels_13 = vol_appels_m1 / (vol_appels_m3 + 1),
      ratio_sms_13    = nb_sms_m1 / (nb_sms_m3 + 1),
      ratio_data_13   = vol_data_m1 / (vol_data_m3 + 1),
      
      # --- moyennes 3 mois
      data_moy_3m   = rowMeans(cbind(vol_data_m1, vol_data_m2, vol_data_m3), na.rm = TRUE),
      appels_moy_3m = rowMeans(cbind(vol_appels_m1, vol_appels_m2, vol_appels_m3), na.rm = TRUE),
      sms_moy_3m    = rowMeans(cbind(nb_sms_m1, nb_sms_m2, nb_sms_m3), na.rm = TRUE),
      
      # --- volatilité
      data_sd_3m   = apply(cbind(vol_data_m1, vol_data_m2, vol_data_m3), 1, sd, na.rm = TRUE),
      appels_sd_3m = apply(cbind(vol_appels_m1, vol_appels_m2, vol_appels_m3), 1, sd, na.rm = TRUE),
      sms_sd_3m    = apply(cbind(nb_sms_m1, nb_sms_m2, nb_sms_m3), 1, sd, na.rm = TRUE),
      
      # --- offre
      baisse_duree_offre = ifelse(
        !is.na(duree_offre_actuelle_h) & !is.na(duree_offre_initiale_h) &
          duree_offre_actuelle_h < duree_offre_initiale_h, 1, 0
      ),
      hausse_duree_offre = ifelse(
        !is.na(duree_offre_actuelle_h) & !is.na(duree_offre_initiale_h) &
          duree_offre_actuelle_h > duree_offre_initiale_h, 1, 0
      ),
      diff_duree_offre_h = duree_offre_actuelle_h - duree_offre_initiale_h,
      passage_illimite = ifelse(offre_init_illimitee == 0 & offre_actu_illimitee == 1, 1, 0),
      sortie_illimite  = ifelse(offre_init_illimitee == 1 & offre_actu_illimitee == 0, 1, 0),
      
      # --- engagement produit
      ratio_options_migrations = nb_options / (nb_migrations + 1),
      client_multi_services = ifelse(nb_options >= 3, 1, 0),
      engagement_premium = ifelse(
        flag_option_tv_illimitee == 1 |
          flag_option_musique_illimitee == 1 |
          flag_option_voyage == 1, 1, 0
      ),
      
      # --- téléphone / profil
      tel_bas_gamme_actuel = ifelse(telephone_actuel == "Bas de gamme", 1, 0),
      jamais_reengage = ifelse(nb_reengagements == 0, 1, 0),
      
      # --- flags churn forts
      sans_engagement = ifelse(mois_fin_engagement < 0, 1, 0),
      fin_engagement_3m = ifelse(mois_fin_engagement <= 3, 1, 0),
      fin_engagement_6m = ifelse(mois_fin_engagement <= 6, 1, 0),
      
      baisse_data_forte = ifelse(evol_data_13 < -0.30, 1, 0),
      baisse_appels_forte = ifelse(evol_appels_13 < -0.30, 1, 0),
      baisse_sms_forte = ifelse(evol_sms_13 < -0.30, 1, 0),
      
      telephone_risque = ifelse(telephone_actuel == "Bas de gamme", 1, 0),
      csp_risque = ifelse(csp %in% c("Etudiant", "Sans emploi", "Employe"), 1, 0)
    ) %>%
    mutate(
      classe_age = case_when(
        is.na(age) ~ NA_character_,
        age < 25 ~ "moins_25",
        age < 35 ~ "25_34",
        age < 50 ~ "35_49",
        TRUE ~ "50_plus"
      ) %>% factor(),
      
      classe_fin_engagement = case_when(
        is.na(mois_fin_engagement) ~ NA_character_,
        mois_fin_engagement < 0 ~ "deja_sans_engagement",
        mois_fin_engagement <= 3 ~ "fin_lt_3",
        mois_fin_engagement <= 6 ~ "fin_3_6",
        TRUE ~ "fin_gt_6"
      ) %>% factor()
    )
}

base_2024_feat <- feature_engineering(base_2024_elig, date_ref_2024)
base_2025_feat <- feature_engineering(base_2025_elig, date_ref_2025)

# ---------------------------------------------------------
# 6. VARIABLES DE MODÉLISATION
# ---------------------------------------------------------
vars_excluded <- c(
  "id_client",
  "code_postal",
  "date_naissance",
  "date_activation",
  "date_fin_engagement",
  "date_dernier_reengagement",
  "anciennete_mois_brut",
  "exclu_trop_recent",
  "exclu_date_activation_future",
  "exclu_fin_engagement_avant_activation",
  "exclu_reengagement_avant_activation"
)

predictor_vars <- setdiff(names(base_2024_feat), c(vars_excluded, "flag_resiliation"))

# ---------------------------------------------------------
# 7. SPLIT APPRENTISSAGE / TEST
# ---------------------------------------------------------
set.seed(123)
split_obj <- initial_split(base_2024_feat, prop = 0.7, strata = flag_resiliation)
train_2024 <- training(split_obj)
test_2024  <- testing(split_obj)

# ---------------------------------------------------------
# 8. RECIPES
# ---------------------------------------------------------
# Version non normalisée
rec_base <- recipe(flag_resiliation ~ ., data = train_2024[, c("flag_resiliation", predictor_vars)]) %>%
  step_unknown(all_nominal_predictors()) %>%
  step_novel(all_nominal_predictors()) %>%
  step_other(all_nominal_predictors(), threshold = 0.01) %>%
  step_impute_median(all_numeric_predictors()) %>%
  step_impute_mode(all_nominal_predictors()) %>%
  step_dummy(all_nominal_predictors()) %>%
  step_zv(all_predictors()) %>%
  step_smote(flag_resiliation)

# Version normalisée
rec_scaled <- rec_base %>%
  step_normalize(all_numeric_predictors())

# ---------------------------------------------------------
# 9. MÉTRIQUES PERSONNALISÉES
# ---------------------------------------------------------
top2000_capture <- function(truth, estimate, n_top = 2000) {
  tmp <- tibble(truth = truth, score = estimate) %>%
    filter(!is.na(score)) %>%
    arrange(desc(score)) %>%
    slice_head(n = min(n_top, nrow(.)))
  
  sum(as.character(tmp$truth) == "1", na.rm = TRUE)
}

lift_top2000 <- function(truth, estimate, n_top = 2000) {
  tmp <- tibble(truth = truth, score = estimate) %>%
    filter(!is.na(score)) %>%
    arrange(desc(score)) %>%
    slice_head(n = min(n_top, nrow(.)))
  
  taux_top <- mean(as.character(tmp$truth) == "1", na.rm = TRUE)
  taux_global <- mean(as.character(truth) == "1", na.rm = TRUE)
  
  taux_top / taux_global
}

eval_model <- function(df, prob_col = ".pred_1", truth_col = "flag_resiliation") {
  auc_val <- roc_auc(df, truth = !!sym(truth_col), !!sym(prob_col), event_level = "second")$.estimate
  cap_2000 <- top2000_capture(df[[truth_col]], df[[prob_col]], 2000)
  lift_2000 <- lift_top2000(df[[truth_col]], df[[prob_col]], 2000)
  
  tibble(
    auc = auc_val,
    captures_top2000 = cap_2000,
    lift_top2000 = lift_2000
  )
}

# ---------------------------------------------------------
# 10. BASELINE LOGIT
# ---------------------------------------------------------
mod_logit <- logistic_reg() %>%
  set_engine("glm")

wf_logit <- workflow() %>%
  add_recipe(rec_scaled) %>%
  add_model(mod_logit)

fit_logit <- fit(wf_logit, data = train_2024)

pred_logit <- predict(fit_logit, new_data = test_2024, type = "prob") %>%
  bind_cols(test_2024 %>% select(flag_resiliation))

res_logit <- eval_model(pred_logit)

# ---------------------------------------------------------
# RANDOM FOREST RAPIDE
# ---------------------------------------------------------

mod_rf_fast <- rand_forest(
  trees = 500,
  mtry = 12,
  min_n = 10
) %>%
  set_engine("ranger", importance = "impurity", probability = TRUE) %>%
  set_mode("classification")

wf_rf_fast <- workflow() %>%
  add_recipe(rec_base) %>%
  add_model(mod_rf_fast)

fit_rf <- fit(wf_rf_fast, data = train_2024)

pred_rf <- predict(fit_rf, new_data = test_2024, type = "prob") %>%
  bind_cols(test_2024 %>% select(flag_resiliation))

res_rf <- eval_model(pred_rf)
res_rf
  

# ---------------------------------------------------------
# 12. XGBOOST TUNÉ
# ---------------------------------------------------------
mod_xgb_tuned <- boost_tree(
  trees = tune(),
  tree_depth = tune(),
  learn_rate = tune(),
  loss_reduction = tune(),
  min_n = tune(),
  sample_size = tune()
) %>%
  set_engine("xgboost") %>%
  set_mode("classification")

wf_xgb_tuned <- workflow() %>%
  add_recipe(rec_base) %>%
  add_model(mod_xgb_tuned)

xgb_grid <- grid_latin_hypercube(
  trees(),
  tree_depth(),
  learn_rate(),
  loss_reduction(),
  min_n(),
  sample_prop(),
  size = 25
)

set.seed(123)

folds <- vfold_cv(train_2024, v = 2, strata = flag_resiliation)

tuned_xgb <- tune_grid(
  wf_xgb_tuned,
  resamples = folds,
  grid = xgb_grid,
  metrics = metric_set(roc_auc)
)

best_xgb_params <- select_best(tuned_xgb, metric = "roc_auc")
final_xgb_wf <- finalize_workflow(wf_xgb_tuned, best_xgb_params)
fit_xgb <- fit(final_xgb_wf, data = train_2024)

pred_xgb <- predict(fit_xgb, new_data = test_2024, type = "prob") %>%
  bind_cols(test_2024 %>% select(flag_resiliation))

res_xgb <- eval_model(pred_xgb)
res_xgb

# ---------------------------------------------------------
# 13. SVM RADIAL TUNÉ
# ---------------------------------------------------------
mod_svm <- svm_rbf(
  cost = 1,
  rbf_sigma = 0.01
) %>%
  set_engine("kernlab") %>%
  set_mode("classification")

wf_svm <- workflow() %>%
  add_recipe(rec_scaled) %>%
  add_model(mod_svm)

fit_svm <- fit(wf_svm, data = train_2024)

pred_svm <- predict(fit_svm, new_data = test_2024, type = "prob") %>%
  bind_cols(test_2024 %>% select(flag_resiliation))

res_svm <- eval_model(pred_svm)
res_svm

# ---------------------------------------------------------
# 14. BLEND DES MEILLEURS MODÈLES
# ---------------------------------------------------------
blend_test <- tibble(
  flag_resiliation = test_2024$flag_resiliation,
  rf = pred_rf$.pred_1,
  xgb = pred_xgb$.pred_1,
  svm = pred_svm$.pred_1
) %>%
  mutate(
    score_blend = 0.50 * rf + 0.30 * xgb + 0.20 * svm
  )

res_blend <- eval_model(blend_test %>% transmute(flag_resiliation, .pred_1 = score_blend))

# ---------------------------------------------------------
# 15. COMPARAISON DES MODÈLES
# ---------------------------------------------------------
comparaison_modeles <- bind_rows(
  res_logit %>% mutate(modele = "logit_scaled"),
  res_rf %>% mutate(modele = "rf_ranger_tuned"),
  res_xgb %>% mutate(modele = "xgboost_tuned"),
  res_svm %>% mutate(modele = "svm_rbf_tuned"),
  res_blend %>% mutate(modele = "blend_rf_xgb_svm")
) %>%
  select(modele, everything()) %>%
  arrange(desc(captures_top2000), desc(auc))

print(comparaison_modeles)

# ---------------------------------------------------------
# 16. CHOIX DU MEILLEUR MODÈLE
# ---------------------------------------------------------
best_model_name <- comparaison_modeles$modele[1]
print(best_model_name)

# on associe l'objet final
best_fit <- switch(
  best_model_name,
  "logit_scaled"      = fit_logit,
  "rf_ranger_tuned"   = fit_rf,
  "xgboost_tuned"     = fit_xgb,
  "svm_rbf_tuned"     = fit_svm,
  "blend_rf_xgb_svm"  = NULL
)

# ---------------------------------------------------------
# 17. IMPORTANCE DES VARIABLES
# ---------------------------------------------------------
if (best_model_name %in% c("rf_ranger_tuned", "xgboost_tuned")) {
  vip(extract_fit_parsnip(best_fit)$fit, num_features = 20)
}

# ---------------------------------------------------------
# 18. PROFILS TYPES SUR TEST
# ---------------------------------------------------------
if (best_model_name != "blend_rf_xgb_svm") {
  pred_best_test <- predict(best_fit, new_data = test_2024, type = "prob") %>%
    bind_cols(test_2024)
  
  profils_haut_risque <- pred_best_test %>%
    arrange(desc(.pred_1)) %>%
    slice_head(n = 10)
  
  profils_faible_risque <- pred_best_test %>%
    arrange(.pred_1) %>%
    slice_head(n = 10)
} else {
  pred_best_test <- blend_test %>%
    rename(.pred_1 = score_blend)
  
  profils_haut_risque <- pred_best_test %>%
    bind_cols(test_2024) %>%
    arrange(desc(.pred_1)) %>%
    slice_head(n = 10)
  
  profils_faible_risque <- pred_best_test %>%
    bind_cols(test_2024) %>%
    arrange(.pred_1) %>%
    slice_head(n = 10)
}

# ---------------------------------------------------------
# 19. APPLICATION À 2025
# ---------------------------------------------------------
# Important : même préparation via workflow déjà appris

if (best_model_name == "blend_rf_xgb_svm") {
  
  pred_2025_rf <- predict(fit_rf, new_data = base_2025_feat, type = "prob") %>%
    rename(rf = .pred_1)
  
  pred_2025_xgb <- predict(fit_xgb, new_data = base_2025_feat, type = "prob") %>%
    rename(xgb = .pred_1)
  
  pred_2025_svm <- predict(fit_svm, new_data = base_2025_feat, type = "prob") %>%
    rename(svm = .pred_1)
  
  pred_2025 <- bind_cols(
    base_2025_feat %>% select(id_client),
    pred_2025_rf,
    pred_2025_xgb,
    pred_2025_svm
  ) %>%
    mutate(
      .pred_1 = 0.50 * rf + 0.30 * xgb + 0.20 * svm
    ) %>%
    select(id_client, .pred_1)
  
} else {
  
  pred_2025 <- predict(best_fit, new_data = base_2025_feat, type = "prob") %>%
    bind_cols(base_2025_feat %>% select(id_client)) %>%
    select(id_client, .pred_1)
}

# ---------------------------------------------------------
# 20. TOP 2000 FINAL
# ---------------------------------------------------------
top_2000_2025 <- pred_2025 %>%
  arrange(desc(.pred_1)) %>%
  slice_head(n = 2000) %>%
  select(id_client)

# ---------------------------------------------------------
# 21. EXPORT
# ---------------------------------------------------------
write.table(
  top_2000_2025,
  file = "C4_Deogratias_V2.txt",
  sep = "\t",
  row.names = FALSE,
  col.names = FALSE,
  quote = FALSE,
  fileEncoding = "Windows-1252"
)

# ---------------------------------------------------------
# 22. EXPORTS UTILES
# ---------------------------------------------------------
write.csv(comparaison_modeles, "comparaison_modeles_v2.csv", row.names = FALSE)

write.csv(pred_2025, "scores_base_2025_v2.csv", row.names = FALSE)