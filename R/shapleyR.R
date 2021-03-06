.onAttach <- function(libname, pkgname) {
  packageStartupMessage("Welcome to the ShapleyR package!")
}
#' Describes the difference between the expected value and the true outcome.
#'
#' @description Calculates the approximated shapley value for every feature for a chosen observation (row.nr).
#' Supported tasks are reggression, multilabeling, clustering and classification tasks.
#' It is also possible to calculate the exact shapley value (not for mlr).
#' You can plot the results with the shiny app (not for multilabel).
#' The Shapley function gives you as output many informations like task type, feature names,
#' predict type, prediction response, mean of data and the shapley values for every feature.
#' You get the information by using the get-functions, which are described below (Getters).
#' For further informations and examples check out our vignette.
#' The shapley algorithm is from this paper (Algorithm 1):
#' Erik Štrumbelj and Igor Kononenko. 2014. Explaining prediction models and individual predictions
#' with feature contributions. Knowl. Inf. Syst. 41, 3 (December 2014), 647-665
#' @param row.nr Index for the observation of interest. It is possible to choose a range of rows.
#' Input has to be a numeric.
#' @param task Machine leraning task
#' @param model Model for the corresponding task. Input has to be a wrapped model.
#' @param iterations Amount of iterations within the shapley function. Input has to be a numeric.
#' @return A shapley object as a list containing several information. Among others the
#' shapley.values are returned as a data.frame with the features as columns and
#' their corresponding effects.
#' @export
shapley = function(row.nr, task, model, iterations = 30) {
  assert_numeric(row.nr, min.len = 1, lower = 1, upper = nrow(getTaskData(task)))
  assert_int(iterations, lower = 1)
  assert_class(model, "WrappedModel")
  assert_set_equal(getTaskId(task), getTaskId(model))

  feature.names = getTaskFeatureNames(task)
  task.type = getTaskType(task)

  x = getTaskData(task)[row.nr,]
  b1 = data.frame(subset(x, select = feature.names))
  b1[1:(nrow(x) * iterations * length(feature.names)),] = NA
  b2 = b1
  result = prepareResult(x, task, model)

  for(f in 1:length(feature.names)) {
    feature = feature.names[f]
    for(i in 1:iterations) {
      z = getTaskData(task)[sample(getTaskSize(task), nrow(x)),]
      perm = sample(feature.names)
      position = match(feature, perm)

      s = (f-1) * nrow(x)*iterations + (i-1) * nrow(x) + 1
      prec = if(position == 1) NULL else perm[1:(position - 1)]
      succ = if(position == length(perm)) NULL else perm[(position + 1):length(perm)]
      b1[s:(s + nrow(x) - 1), perm] = cbind(x[prec], x[feature], z[succ])
      b2[s:(s + nrow(x) - 1), perm] = cbind(x[prec], z[feature], z[succ])
    }
  }

  predict_b1 = getPredictionData(b1, model, task)
  predict_b2 = getPredictionData(b2, model, task)
  nclasses = 1
  if(task.type %in% c("classif", "multilabel"))
    nclasses = length(getTaskClassLevels(task))
  if(task.type == "cluster")
    nclasses = model$learner$par.vals$centers

  for(f in 1:length(feature.names)) {
    feature = feature.names[f]
    for(i in 1:nrow(x)) {
      r.indices = nclasses * (i - 1) + 1:nclasses
      p.indices = custom.ifelse(getLearnerPredictType(model$learner) == "response",
        seq((f-1) * nrow(x) * iterations + i, f * nrow(x) * iterations, nrow(x)),
        iterations * (i-1) + 1:iterations)
      result[r.indices, feature] = computePartialResult(predict_b1, predict_b2, p.indices, task.type)
    }
  }

  result = list(
    task.type = task.type,
    feature.names = getTaskFeatureNames(task),
    predict.type = getLearnerPredictType(model$learner),
    prediction.response = computeResponse(x, model),
    data.mean = computeDataMean(task, model),
    values = result
  )

  return(result)
}

getPredictionData = function(data, model, task) {
  result = NA
  response.types = c("classif", "cluster", "multilabel")
  if(getLearnerPredictType(model$learner) == "response" &  getTaskType(task) %in% response.types) {
    task.levels = custom.ifelse(getTaskType(task) == "cluster",
      seq(1, model$learner$par.vals$centers, by = 1), getTaskClassLevels(task))
    response = getPredictionResponse(predict(model, newdata=data))
    result = as.data.frame(matrix(data = 0, nrow = nrow(data), ncol = length(task.levels)))
    names(result) = task.levels
    for(i in 1:nrow(result))
      result[i, as.character(response[i])] = 1
  } else if(getTaskType(task) == "regr") {
    result = as.data.frame(getPredictionResponse(predict(model, newdata=data)))
  } else if(getTaskType(task) == "classif") {
    result = getPredictionProbabilities(predict(model, newdata=data), getTaskClassLevels(task))
  } else if(getTaskType(task) == "cluster") {
    result = getPredictionProbabilities(predict(model, newdata=data))
  }

  return(result)
}

prepareResult = function(x, task, model) {
  task.levels = NA
  if(getTaskType(task) %in% c("classif", "multilabel")) {
    task.levels = getTaskClassLevels(task)
  } else if(getTaskType(task) == "cluster") {
    task.levels = seq(1, model$learner$par.vals$centers)
  }
  custom.names = c("_Id", "_Class")
  result = as.data.frame(matrix(data = 0, ncol = getTaskNFeats(task) + length(custom.names),
    nrow = nrow(x) * length(task.levels)))
  names(result) = c(custom.names, getTaskFeatureNames(task))
  for(i in 1:nrow(x)) {
    s = (i - 1) * length(task.levels) + 1
    result$"_Id"[s:(s+length(task.levels)-1)] = rep(row.names(x)[i], times = length(task.levels))
  }
  result$"_Class" = rep(task.levels, times = nrow(x))

  return(result)
}

computePartialResult = function(predict_a, predict_b, indices, task_type) {
  result = predict_a[indices,] - predict_b[indices,]
  if(task_type == "regr")
    result = round(mean(result), 3)
  else
    result = round(colMeans(result), 3)

  return(result)
}

computeDataMean = function(task, model) {
  result = NA
  if(getTaskType(task) == "regr") {
    result = mean(getPredictionTruth(predict(model, newdata = getTaskData(task))))
  } else {
    tab = as.data.frame(table(getPredictionResponse(predict(model, newdata = getTaskData(task)))))
    result = tab[,2]
    names(result) = tab[,1]
    result = result / sum(result)
  }

  return(result)
}

computeResponse = function(x, model) {
  result = NA
  if(getLearnerPredictType(model$learner) == "prob") {
    result = round(getPredictionProbabilities(predict(model, newdata = x)), 5)
  } else {
    result = getPredictionResponse(predict(model, newdata = x))
  }

  return(result)
}

custom.ifelse = function(condition, then.case, else.case) {
  if(condition)
    return(then.case)
  else
    return(else.case)
}
