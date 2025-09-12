test_that("generate_sample_data produces correct output", {
  data <- generate_sample_data(n_samples = 1000, seed = 123)

  # Verificar estrutura básica
  expect_equal(nrow(data), 1000)
  expect_equal(ncol(data), 16)
  expect_true(all(c("applicant_id", "score_1", "score_2", "score_3",
                    "score_4", "score_5") %in% names(data)))

  # Verificar intervalos dos scores
  expect_true(all(data$score_1 >= 300 & data$score_1 <= 850))
  expect_true(all(data$score_2 >= 300 & data$score_2 <= 850))
  expect_true(all(data$score_3 >= 300 & data$score_3 <= 850))
  expect_true(all(data$score_4 >= 300 & data$score_4 <= 850))
  expect_true(all(data$score_5 >= 300 & data$score_5 <= 850))

  # Verificar que os decils de risco estão entre 1 e 10
  expect_true(all(data$risk_decile >= 1 & data$risk_decile <= 10))

  # Verificar que as datas estão dentro do intervalo esperado
  expect_true(all(data$application_date >= as.Date("2023-01-01")))
  expect_true(all(data$application_date <= as.Date("2023-12-31")))

  # Verificar que as variáveis binárias são 0 ou 1
  expect_true(all(data$prev_credit_approval %in% c(0, 1)))
  expect_true(all(data$prev_antifraud_approval %in% c(0, 1)))
  expect_true(all(data$prev_fpd_30 %in% c(0, 1)))
  expect_true(all(data$existing_customer %in% c(0, 1)))
})

test_that("sample data is reproducible with seed", {
  data1 <- generate_sample_data(n_samples = 100, seed = 123)
  data2 <- generate_sample_data(n_samples = 100, seed = 123)

  expect_equal(data1, data2)
})
