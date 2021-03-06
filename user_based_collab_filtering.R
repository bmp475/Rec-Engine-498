library(aws.s3) # https://github.com/cloudyr/aws.s3
library(readr)
library(lubridate)
library(dplyr)
library(tidyr)
library(ggplot2)
library(pryr) # memory usage functions

# specify keys as environment variables so I can read my s3 object(s) from AWS.
# Your unique access key/secret needs to be passed before running the queries below. 
Sys.setenv("AWS_ACCESS_KEY_ID" = "",
           "AWS_SECRET_ACCESS_KEY" = "")


# Read obfuscatedItems_10_17_17.txt & obfuscatedWebActivity_10_16_17.txt from S3 ------

# items data: part number, parent, catalogue, attributes/values.
# parse warning, but get identical results if using read.table and comparing results with all.equal()
items <- s3read_using(FUN = read_table2, 
                      object = "obfuscatedItems_10_17_17.txt", 
                      col_names = TRUE,
                      col_types = "cciciiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiii",
                      bucket = "pred498team5")

# user click data from the company website for a random day of user's selected,
# their activity for past 3 months, and click summaries of how they interacted with parts. 
users <- s3read_using(FUN = read_table2, 
                      col_names = TRUE,
                      col_types = "ccici",
                      object = "obfuscatedWebActivity_10_16_17.txt", 
                      bucket = "pred498team5")

# left join the parent family to the users PartNumber
user_items <- users %>%
  left_join(items, by = "PartNumber") %>%
  mutate(ActionDate = ymd(ActionDate)) %>% # parse into a date format.
  select(-starts_with("Val"), -starts_with("Attr"), -starts_with("Catalog"))

all.equal(users[1:3], user_items[1:3]) # users matches the first 3 columns after join. 
remove(users)
remove(items)

# save an in-memory R object into S3
s3save(user_items, bucket = "pred498team5", object = "user_items.Rdata")





# load the user_items.Rdata object from S3. ------------------------------------
# This is the data wrangled from lines 14-44. Loads the user_items dataframe. 
s3load("user_items.Rdata", bucket = "pred498team5")




# Create Action Labels and convert to 1-2-3 Ratings scale in user_items --------
# see explore_users_parts_data.R, lines 206 - 262 for analysis.

# create labels for ActionId
user_items <- user_items %>%
  # convert raw ActionId into labeled values. 
  mutate(ActionId_label = factor(user_items$ActionId, 
                                 labels = c("add to order", "select Part",
                                            "select Part detail",
                                            "print detail",
                                            "save CAD drawing detail",
                                            "print CAD drawing detail")),
         # categorize the 6 actions into 3 ratings, based on similarity.
         # order from lowest to highest implicit rating. implicit to a purchase event.
         # 1 = basic, 2 = moderate, 3 = close to a purchase or high interest to visitor. 
         action_rating = if_else(ActionId_label == "select Part", 1, 
                                 if_else(ActionId_label == "select Part detail", 2, 3)))

user_items %>%
  group_by(ActionId, ActionId_label, action_rating) %>%
  summarize(frequency = n()) %>%
  ungroup() %>%
  mutate(propn = round(frequency / sum(frequency), 2)) %>%
  arrange(action_rating, desc(frequency))

user_items %>%
  group_by(action_rating) %>%
  summarize(frequency = n())


# Sample pre-processing of ratings data (1000 rows) to see if it works----------
update <- user_items %>%
  select(VisitorId, Parent, PartNumber, ActionDate, starts_with("Action")) %>%
  arrange(VisitorId, Parent, ActionDate) %>%
  slice(1:1000)


# Step 1: Analyze each Visitor Session (day) with a Parent# and extract max action. 
update2 <- update %>%
  # create window for each visitor's session with a Parent Part#, each day. 
  group_by(VisitorId, Parent, ActionDate) %>%
  # w/in window, keep row(s) of max action_rating for that specific session.
  filter(action_rating == max(action_rating)) %>%
  arrange(VisitorId, Parent, ActionDate) %>%
  ungroup()

# Step2: within Visitor Session with Parent#, sum up all max action_ratings to 
# account for >1 max actions with diff. PartNumbers of that Parent# during session. Additive weight. 
update3 <- update2 %>%
  # create window for each visitor's session with a Parent Part#, each day.
  select(-ActionCount) %>%
  group_by(VisitorId, Parent, ActionDate) %>%
  # w/in window, keep row of max action_rating for that specific session.
  # There may be doops per Visitor session (day) with specific Parent b/c there 
  # could be multiple PartNumbers associated w/same Parent doing same max action_rating.
  filter(action_rating == max(action_rating)) %>%
  # sum max action_rating w/in user session per Parent#. Example, Visitor#1000368642442
  # had a session on 6/22/2017 where for 6 different PartNumbers of the 
  # same Parent#P65-307800, the visitor clicked "add to order". So instead of a 
  # rating of just 3 for the Parent#, it should be 18 (3*6) to account for how
  # much they implicitely like different PartNumbers w/in Parent#P65-307800.
  summarize(session_action_rating = sum(action_rating)) %>%
  arrange(VisitorId, Parent, ActionDate) %>%
  ungroup()

summary(update3$session_action_rating)
# Each row is now a unique Visitor Session with specific Parent# and the session's rating.
nrow(distinct(update3)) == nrow(update3)

# Step3: per Parent per Visitor, sum the session_action_rating across all sessions (days). 
# Intuition: If the visitor has had repeat actions with the Parent# over many 
# different sessions(days), we can interpret they rate this Part Parent Group very highly. 
update4 <- update3 %>%
  group_by(VisitorId, Parent) %>%
  summarize(total_rating = sum(session_action_rating))


summary(update4$total_rating)

update4 %>%
  ggplot(aes(total_rating)) + 
  geom_histogram(binwidth = 1, colour = "black", fill = "darkgrey") +
  # median vertical line.
  geom_vline(aes(xintercept = median(total_rating)),
             color = "blue", linetype = "dashed", size = 0.5) +
  geom_text(aes(0,70, label = paste("median = ", median(total_rating))),
            nudge_x = 7, color = "blue", size = 4.5) +
  labs(title = 'Total Aggregated Rating of Parent# per Visitor',
       subtitle = 'Based only on sample of 1000 rows of web activity actions')

# Step4:  right-tailed weighted ratings after these weights are accounted for 
# across sessions, so transform them in some way (ex. log, sqrt) or coerce them 
# to some upper limit (ex. cutoff at 10). Some examples below. 
update5 <- update4 %>%
  mutate(total_rating_sqrt = sqrt(total_rating),
         total_rating_logn = log(total_rating),
         total_ratin_max10 = ifelse(total_rating > 10, 10, total_rating))

summary(update5)
# Coercing to upper limit of 10 looks promising.
update5 %>%
  gather(key = rating_type, value = value, -VisitorId, -Parent) %>%
  ggplot(aes(value, fill = rating_type)) +
    geom_histogram(binwidth = max(value) - min(value), colour = "black") +
    facet_wrap(~ rating_type)





# Full pre-processing of ratings data ------------------------------------------
user_ratings <- user_items %>%
  select(VisitorId, Parent, ActionDate, action_rating) %>%
  # create group window for each Visitor's individual session(day) with a Parent# 
  group_by(VisitorId, Parent, ActionDate) %>%
  # Step1: w/in window, keep row(s) of max action_rating for that specific session.
  filter(action_rating == max(action_rating)) %>%
  # Step2: sum up all max action_ratings to account for >1 max actions with diff. 
  # PartNumbers of that Parent# during session. An additive weight w/in session of a Parent#.
  summarize(session_action_rating = sum(action_rating)) %>%
  # change group window to roll up next aggregations to Visitor:Parent, across all sessions. 
  group_by(VisitorId, Parent) %>%
  # Step3: per Parent per Visitor, sum the session_action_rating across all sessions (days).
  summarize(total_rating = sum(session_action_rating)) %>%
  ungroup() %>%
  arrange(VisitorId, total_rating)


summary(user_ratings$total_rating)

user_ratings %>%
  ggplot(aes(total_rating)) + 
  geom_histogram(binwidth = 5, colour = "black", fill = "darkgrey") +
  # median vertical line.
  labs(title = 'Parent Family# Total Rating Distribution',
       subtitle = 'Per each Visitor in full dataset')

# Step4:  right-tailed weighted ratings after these weights are accounted for 
# across sessions, so transform them in some way (ex. log, sqrt) or coerce them 
# to some upper limit (ex. cutoff at 10). Some examples below. 
user_ratings <- user_ratings %>%
  mutate(total_rating_sqrt = sqrt(total_rating),
         total_rating_logn = log(total_rating),
         total_rating_max10 = ifelse(total_rating > 10, 10, total_rating))

summary(user_ratings[3:6])
# Coercing to upper limit of 10 looks promising.
tidy_ratings <- user_ratings %>%
  gather(key = rating_type, value = value, -VisitorId, -Parent)

tidy_ratings %>%
  ggplot(aes(value, fill = rating_type)) +
  geom_histogram(data = filter(tidy_ratings, rating_type == "total_rating"), binwidth = 10, color = "black") + 
  geom_histogram(data = filter(tidy_ratings, rating_type != "total_rating"), binwidth = 1, color = "black") + 
  facet_wrap(~ rating_type, scales = "free") +
  labs(title = "Distribution of Visitors' Total Rating of Parent Part Families",
       subtitle = "with different rating transformations")

remove(tidy_ratings)



# Convert user_ratings into a sparseMatrix -------------------------------------
library(Matrix)

# https://stackoverflow.com/questions/28430674/create-sparse-matrix-from-data-frame?noredirect=1&lq=1
# the VisitorId and Parent need to be 1 based indices when creating a matrix. 
# Per ?factor, the levels of a factor are by default sorted.
sparse_r <- sparseMatrix(i = as.integer(as.factor(user_ratings$VisitorId)),
                         j = as.integer(as.factor(user_ratings$Parent)),
                         x = user_ratings$total_rating_max10)

# can rename the matrix row and column labels with unique VisitorId and Parent names. 
dimnames(sparse_r) <- list(sort(unique(user_ratings$VisitorId)),
                           sort(unique(user_ratings$Parent)))

# check that the levels of the factor are identical position matches to dimnames 
# being passed to the row and column labels of the sparse matrix. 
all.equal(levels(as.factor(user_ratings$VisitorId)), # line 230
          sort(unique(user_ratings$VisitorId))) # line 235
all.equal(levels(as.factor(user_ratings$Parent)), # line 231
          sort(unique(user_ratings$Parent))) # line 236

class(sparse_r)
dim(sparse_r)
attributes(sparse_r)
str(sparse_r) # it's an S4 object. use slots (@) to access elements. 

# Bring sparse ratings matrix into Recommenderlab ------------------------------
library(recommenderlab)
methods(class = "realRatingMatrix")
methods(class = "binaryRatingMatrix")

# coercse sparseMatrix into a realRatingMatrix object
real_r <- as(sparse_r, "realRatingMatrix")
str(real_r)
real_r

# preview the first 100 visitors total count of non-missing implicit ratings.
rowCounts(real_r[1:100,])

# preview of the ratings matrix of visitors (rows) and their Parent# ratings (col).
getRatingMatrix(real_r[50:100, 1000:1010])

# realRatingsMatrix can be coerced into a list of users with their ratings for 
# closer inspection or into a data.frame for the 1st user, 1000261260099, 
# look at all items they implicitely rated. 
as(real_r[1,], "list")
as(real_r[1,], "data.frame")

# extract the non-missing ratings as a vector to summarize the ratings. same as 
# summary() of the user_ratings vector of total_rating_max10.
summary(getRatings(real_r)); all.equal(summary(getRatings(real_r)), summary(user_ratings$total_rating_max10))

# same plot as before from the tidy dataframe for total_rating_max10. 
data.frame(ratings = getRatings(real_r)) %>%
  ggplot(aes(ratings, y = ..density..)) + geom_histogram(binwidth = 1, color = "black") +
  labs(title = 'Parent# Total Ratings Distribution')

# Build User-Based Collaborative Filtering Model--------------------------------

# types of collaborative filtering algorithms
recommenderRegistry$get_entries(dataType = "realRatingMatrix")
recommenderRegistry$get_entries(dataType = "binaryRatingMatrix")

# UBCF_realRatingMatrix
recommenderRegistry$get_entries(dataType = "realRatingMatrix")$UBCF_realRatingMatrix # tuning parameters
recommenderRegistry$get_entries(dataType = "realRatingMatrix")$UBCF_realRatingMatrix$parameters # tuning parameters


# need to subset the population of visitors to keep records that have enough ratings
# data for evaluation on test data. For the "Given" parameter of the evaluation
# scheme, x randomly chosen items per test visitor row are given to the fitted
# recommender algorithm to learn the model (i.e. nearest neighbor similarity). 
# remainder of each test visitor's items unseen by the algorithm are used for
# measuring predictive performance. Therefore, the "given" threshold must be
# higher than the minimum number of items for any visitor record so there is 
# enough test data to learn the algorithm and measure predictive performance. 
min(rowCounts(real_r)) # must keep n rec. items > min(rowCounts(movie_r))
summary(rowCounts(real_r))

# Distribution of different Parent# interacted by each VisitorId
rowCounts(real_r) %>%
  data.frame(parent_interactions_per_person = .) %>%
  ggplot(aes(x = parent_interactions_per_person, y = ..density..)) + 
  geom_histogram(binwidth = 10, colour = "black", fill = "darkgrey") +
  geom_vline(aes(xintercept = median(parent_interactions_per_person)),
             color = "dodgerblue3", linetype = "dashed", size = 0.5) +
  geom_text(aes(0,.01, family = "courier", 
                label = paste("median = ", median(parent_interactions_per_person))), 
            nudge_x = 150, color = "dodgerblue3", size = 4.5) +
    labs(title = 'Distribution of Parent Part# Interactions per VisitorId',
         subtitle = "binwidth set to 10")


real_r_over5 <- real_r[rowCounts(real_r) > 5, ]
# real_r_over10 <- real_r[rowCounts(real_r) > 10, ]

nrow(real_r) - nrow(real_r_over5) # dropped 504 Visitor records.
min(rowCounts(real_r_over5))
summary(rowCounts(real_r_over5))

# Filter out Columns that are too sparse, almost no raters in them. 
min(colCounts(real_r)) 
summary(colCounts(real_r))

# Distribution of different Parent# interacted by each VisitorId. 
# THIS IS THE LONG-TAIL PHENOMENON.
# Should consider dropping items with too few ratings. . . . . 
colCounts(real_r) %>%
  data.frame(parent_interactions_per_person = .) %>%
  ggplot(aes(x = parent_interactions_per_person, y = ..density..)) + 
  geom_histogram(binwidth = 10, colour = "black", fill = "darkgrey") +
  geom_vline(aes(xintercept = median(parent_interactions_per_person)),
             color = "dodgerblue3", linetype = "dashed", size = 0.5) +
  geom_text(aes(0,.01, family = "courier", 
                label = paste("median = ", median(parent_interactions_per_person))), 
            nudge_x = 150, color = "dodgerblue3", size = 4.5) +
  labs(title = 'Distribution of Count of VisitorId interactions per Parent Part#',
       subtitle = "binwidth set to 10")


# define parameters for model evaluation scheme.
?evaluationScheme
train_proportion <- .80
use_n_test_records_per_user <- 5 # use 5 records per test user to learn model.
good_rating <- 3 # a good rating threshold for a binary classifier?


# Create the evaluation scheme for fitting and testing the recommender algorithm.
set.seed(123)
model_train_scheme <- real_r_over5 %>%
  evaluationScheme(method = 'split', # single train/test partition
                   train = train_proportion, # random sample proportion.
                   given = use_n_test_records_per_user, 
                   goodRating = good_rating,
                   k = 1)

# Fit a UBCF recommender system algorithm. 
# Building a Recommender System with R by Gorakala and Usuelli. Ch.4 pp 84
model_params <- list(method = "cosine",
                     nn = 25, # find each user's 25 most similar users.
                     sample = FALSE, # already did this.
                     # centered cosine similarity > raw cosine similarity.
                     # https://youtu.be/h9gpufJFF-0?list=PLPEu1YFt_zElULdcZBwiDOtOiNLXErWos&t=332
                     normalize = "center")

# Model1: centered cosine similarity.
model1 <- getData(model_train_scheme, "train") %>% 
  Recommender(method = "UBCF", parameter = model_params)

# Model2: raw cosine similarity.
model2_params <- list(method = "cosine",
                     nn = 25, 
                     sample = FALSE, 
                     normalize = NA)

model2 <- getData(model_train_scheme, "train") %>% 
  Recommender(method = "UBCF", parameter = model2_params)

# Model3: raw Pearson Correlation similarity.
model3_params <- list(method = "pearson",
                      nn = 25, 
                      sample = FALSE,
                      normalize = NA)

model3 <- getData(model_train_scheme, "train") %>% 
  Recommender(method = "UBCF", parameter = model3_params)

# Model3: raw Pearson Correlation similarity.
model4_params <- list(method = "pearson",
                      nn = 25, 
                      sample = FALSE,
                      normalize = "center")

model4 <- getData(model_train_scheme, "train") %>% 
  Recommender(method = "UBCF", parameter = model4_params)

# 5.5 - 5.6. Evaluation of predicted ratings in recommenderLab vignette. 
# can use n = for predicting TopN or type = for predicting ratings.
# https://cran.r-project.org/web/packages/recommenderlab/vignettes/recommenderlab.pdf
# takes 14 minutes to run. 
#Take < 2 min on m4.large.

model1_pred <- predict(model1, getData(model_train_scheme, "known"), type = "ratings")
s3save(model1_pred, bucket = "pred498team5", object = "model1_pred.Rdata")
#s3load(model1_pred, bucket = "pred498team5", object = "model1_pred.Rdata")
model1_pred

model2_pred <- predict(model2, getData(model_train_scheme, "known"), type = "ratings")
#s3save(model2_pred, bucket = "pred498team5", object = "model2_pred.Rdata")
#s3load(model2_pred, bucket = "pred498team5", object = "model2_pred.Rdata")


model3_pred <- predict(model3, getData(model_train_scheme, "known"), type = "ratings")
#s3save(model3_pred, bucket = "pred498team5", object = "model3_pred.Rdata")
#s3load(model3_pred, bucket = "pred498team5", object = "model3_pred.Rdata")

model4_pred <- predict(model4, getData(model_train_scheme, "known"), type = "ratings")
#s3save(model4_pred, bucket = "pred498team5", object = "model4_pred.Rdata")
#s3load(model4_pred, bucket = "pred498team5", object = "model4_pred.Rdata")

test_error <- rbind(
  UBCF_centered_cosine = calcPredictionAccuracy(model1_pred, 
                                                getData(model_train_scheme, "unknown"), 
                                                byUser = FALSE),
  UBCF_raw_cosine = calcPredictionAccuracy(model2_pred, 
                                           getData(model_train_scheme, "unknown"), 
                                           byUser = FALSE),
  UBCF_raw_pearson = calcPredictionAccuracy(model3_pred, 
                                            getData(model_train_scheme, "unknown"), 
                                            byUser = FALSE),
  UBCF_centered_pearson = calcPredictionAccuracy(model4_pred, 
                                            getData(model_train_scheme, "unknown"), 
                                            byUser = FALSE))

test_error


# Use library(microbenchmark) to measure runtime of evaluating models on new data.
# https://www.r-bloggers.com/using-the-microbenchmark-package-to-compare-the-execution-time-of-r-expressions/