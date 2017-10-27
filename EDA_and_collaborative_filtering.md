-   [Introduction](#introduction)
-   [Getting the data into R](#getting-the-data-into-r)
-   [Initial Data Wrangling](#initial-data-wrangling)
-   [Descriptions of the User & Items Data](#descriptions-of-the-user-items-data)
    -   [Weekly Users and Total Clicks](#weekly-users-and-total-clicks)
    -   [Description of Unique Visitors, PartNumbers, Parents](#description-of-unique-visitors-partnumbers-parents)
    -   [How do total Action Counts of each visitor distribute?](#how-do-total-action-counts-of-each-visitor-distribute)
    -   [How many unique PartNumbers is each visitor interacting with?](#how-many-unique-partnumbers-is-each-visitor-interacting-with)
    -   [How many unique Parents are visitors interacting with?](#how-many-unique-parents-are-visitors-interacting-with)
    -   [How many unique visitors have interacted with each PartNumber?](#how-many-unique-visitors-have-interacted-with-each-partnumber)
    -   [How many unique visitors have interacted with each Parent Family?](#how-many-unique-visitors-have-interacted-with-each-parent-family)
        -   [Impact of Long Tail Distributions](#impact-of-long-tail-distributions)
    -   [How many PartNumbers fall into each Parent Family?](#how-many-partnumbers-fall-into-each-parent-family)
    -   [Do Parents with more PartNumbers also have more Visitors?](#do-parents-with-more-partnumbers-also-have-more-visitors)
    -   [What types of click Actions do the visitors take?](#what-types-of-click-actions-do-the-visitors-take)
    -   [(TO EXPLORE) What percent of the time is selecting a part a precursor to adding to cart?](#to-explore-what-percent-of-the-time-is-selecting-a-part-a-precursor-to-adding-to-cart)
-   [More Data Wrangling: Creating Ratings](#more-data-wrangling-creating-ratings)
    -   [Convert Actions to Implicit Ratings](#convert-actions-to-implicit-ratings)
    -   [Creating a weighted Total Rating per item](#creating-a-weighted-total-rating-per-item)
    -   [Different Scale Transformations for Total\_ratings](#different-scale-transformations-for-total_ratings)
    -   [Setting up a User Ratings Matrix](#setting-up-a-user-ratings-matrix)
-   [Collaborative Filtering Algorithms](#collaborative-filtering-algorithms)
-   [User Based Collaborative Filtering](#user-based-collaborative-filtering)
-   [Item Based Collaborative Filtering](#item-based-collaborative-filtering)

Introduction
------------

This Markdown file has most of my code, relevant plots, and explanations of decisions made so far in the data wrangling process.

I will update it with collaborative filtering model information too, as needed.

Getting the data into R
-----------------------

I used the following packages to do most of the initial data pre-processing and exploratory analysis. I'm working on an AWS AMI instance that's a linux machine with RStudio and git installed, using one of the instances publicly available and pre-configured from [Louis Aslett's website](http://www.louisaslett.com/RStudio_AMI/). I initially started with the free tier, *t2.micro* instance, but once I started the modeling phase, I scaled up to *m4.large*, which is also a general purpose computing instance but with better RAM, CPU, and better optimized memory management. AWS AMI instance costs can be calculated [here](https://calculator.s3.amazonaws.com/index.html).

The datasets queried by Matt Hayden, I've put in my own S3 Bucket on Amazon Web Services (AWS). As such, the `aws.s3` [package](https://github.com/cloudyr/aws.s3) was used to access that bucket and bring the datasets into my environment. Access Keys are needed to make read/write calls to the bucket, but I've intentionally left that code out of here.

``` r
library(aws.s3) 
library(readr) # faster alternatives to base read. methods. 
library(lubridate) # date wrangling. 
library(dplyr) # data wrangling
library(tidyr) # data wrangling
library(ggplot2) # data viz. 
library(pryr) # mem_used() and object_size() functions to manage/understand memory usage.
```

To read the Part items data and the user webactivity data from s3 I passed read\_table2() functions for reading tabular data to read items dataset and the read\_csv() function to read in the web user click data CSV files.

``` r
# items: part number, parent, catalogue, attributes/values.
items <- s3read_using(FUN = read_table2, 
                      object = "obfuscatedItems_10_17_17.txt", 
                      col_names = TRUE,
                      col_types = "cciciiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiii",
                      bucket = "pred498team5")

# users: click data from the company website for a random day of user's selected, their activity for past 3 months and click summaries of how they interacted with parts. 

# web user click data from Feb - Mar 2017
users_febmar17 <- s3read_using(FUN = read_csv, 
                      col_names = TRUE,
                      col_types = "ccici",
                      object = "obfuscatedWebActivity7124.csv", 
                      bucket = "pred498team5")

# web user click data from April - June 2017
users_aprmayjun17 <- s3read_using(FUN = read_csv, 
                      col_names = TRUE,
                      col_types = "ccici",
                      object = "obfuscatedWebActivity7127.csv", 
                      bucket = "pred498team5")

# web user click data from July - August 2017
users_julaug17 <- s3read_using(FUN = read_csv, 
                      col_names = TRUE,
                      col_types = "ccici",
                      object = "obfuscatedWebActivity7129.csv", 
                      bucket = "pred498team5")
```

The 3 separate user click activity queries performed by Matt on his company's graph database were required in order to get around maximum data request requirements. They contain the same information, with the following columns:

``` r
names(users_aprmayjun17)
```

    [1] "VisitorId"   "PartNumber"  "ActionId"    "ActionDate"  "ActionCount"

These 3 datasets of user click activity covering different time periods between February - August 2017 need to be unioned, or combined, into a single dataset.

``` r
users <- bind_rows(users_febmar17, users_aprmayjun17, users_julaug17)
```

Initial Data Wrangling
----------------------

The **items** dataset contains [obfuscated](https://en.wikipedia.org/wiki/Obfuscation_(software)) information about all of the PartNumbers in the company's inventory, as well as information on the catalog that the PartNumber may have been listed in, and the first 20 attributes and attribute values describing the specifications of each PartNumber. It is a very large dataset with 583768 rows, representing the unique PartNumbers.

The only information we're particularly interested in from the **items** dataset is the Parent column, and left joining that to the matching PartNumber in the users data. Building a recommender system using the Parent family instead of the specific PartNumber will be discussed later. The items dataset has a lot of columns that describe attributes of each PartNumber and Parent. For purposes of a collaborative filtering model, we don't need to know these, any columns that include *"Attr"*, *"Val"*, or *"Catalog"* in its name are dropped.

``` r
user_items <- users %>%
  left_join(items, by = "PartNumber") %>%
  mutate(ActionDate = ymd(ActionDate), # parse into a date format.
         ActionId_label = factor(ActionId, # create labels
                                 labels = c("add to order", "select Part",
                                            "select Part detail",
                                            "print detail",
                                            "save CAD drawing detail",
                                            "print CAD drawing detail"))) %>% 
  select(-starts_with("Val"), -starts_with("Attr"), -starts_with("Catalog"))
```

Check that the left join preserved all of the original data in our full users dataset after joining in the Parent value associated with each PartNumber searched by users.

``` r
all.equal(users[1:5], user_items[1:5])
```

    [1] "Incompatible type for column `ActionDate`: x character, y numeric"

Our original datasets are taking up a lot of memory. Specifically, all other datasets other than user\_items are currently taking up 7.382793610^{8}MB of RAM. We'll remove them since everything we need in terms of user click data, the PartNumbers, Parent, actions taken, and the action date are all in the user\_items dataset. Our main user\_items dataset is quite large, requiring 4.165096310^{8} MB of RAM.

``` r
# We can remove the other datasets we don't need anymore to save available RAM. 
remove(users, items, users_febmar17, users_aprmayjun17, users_julaug17)
```

Descriptions of the User & Items Data
-------------------------------------

The user click data (**may refer to users interchangeably as visitors**) came from three separate graph database queries that were required in order to get around maximum data request requirements. Together, the 3 user datasets represent click data from a **random sample** of accounts that purchase from the company's website who had made purchases recently. These visitor's individual click activities were queried over a time period from 2017-01-31 through 2017-09-08, covering a range of 220 days. Therefore, these data may provide insight into how users/visitors of a manufacturing supplier are interacting with the company's website, which can form the basis of learning from and providing recommendations on items tailored to each user's behavior and interests to improve the user experience and find items faster. Each variable in the main dataset is defined as follows:

-   **VisitorId**: This represents the unique account associated with the customer. It is not based on IP address or other geo-tagging information. The queries set up to curate this dataset were intentionally focused on identifying actual customers with account logins who have purchased from the company in the past. There are 23997 unique VisitorIDs in this random sample of user data.

-   **PartNumber**: This represents the ID of the specific product Part Number (ex. a pair of gloves, welding mask, pipe, cable, screw) that the VisitorId interacted with in some way(s) during their web session.

-   **Parent**: The Parent level is the hierarchical category of similar products that every specific PartNumbers roll up to. Within the copmany website, it's a hyperlink associated with the PartNumber. Parent groups will vary in size. It is a way that individual merchandising managers at the company decide to categorize and organize the hundreds of thousands of PartNumbers.

-   **ActionId**: represents the type of click action that occurred. There are 6 unique actions that a user can take, which are defined by the next variable for each value of ActionId.

-   *ActionId\_label*: The 6 unique actions for each ActionId value are
    -   *1 = add to order*: the user added the PartNumber to their order.
    -   *2 = select Part*: the user clicked on the PartNumber to get more information. This is the most basic user action.
    -   *3 = select Part detail*: the user selected to drill in for more detail about the PartNumber interacting with.
    -   *4 = print detail*: the user selected to print the detail about the PartNumber that they drilled into.
    -   *5 = save CAD drawing detail*: the user saved the computer aided draft (CAD) drawing about the PartNumber.
    -   *6 = print CAD drawing detail*: the user printed the computer aided draft (CAD) drawing about the PartNumber.
-   **ActionDate**: This is the date of the user's session with a specific PartNumber(s). A user may have had multiple sessions with different PartNumbers in the same day.

-   **ActionCount**: For each ActionId that a user took while interacting with a PartNumber within a session, a count of 1 is recorded. So if visitor X interacted with PartNumber Y today by going back and forth and selecting the same PartNumber three times within this day's session, visitor X's ActionCount for PartNumber Y for today will be 3.

With a baseline dataset and description of the different variables provided above, we can start describing some information about the user activity.

Again, the web activity covered by these user clicks on the website begins on 2017-01-31 and goes through 2017-09-08, covering a span of 220 days.

### Weekly Users and Total Clicks

``` r
weekly_activity <- user_items %>%
  mutate(week_ending_date = ceiling_date(ActionDate, "week")) %>%
  group_by(week_ending_date) %>%
  summarize(unique_users = length(unique(VisitorId)),
            total_clicks = n()) %>%
  arrange(week_ending_date)

temp <- weekly_activity %>%
  mutate(week_ending_date = as.Date(week_ending_date, "%Y-%m-%d")) 


weekly_activity %>%
  mutate(week_ending_date = as.Date(week_ending_date, "%Y-%m-%d")) %>% 
  gather(key = key, value = value, -week_ending_date) %>%
  ggplot(aes(x = week_ending_date, y = value, group = key)) +
    geom_line(aes(color = key)) +
    scale_x_date(date_breaks = ("1 month"),
               date_labels = c(month.name[1:9])) +
    scale_y_continuous(labels = function(n) format(n, scientific = FALSE)) + # raw frequency scale
    labs(title = "Weekly Distribution of Sample of Users and their total click Actions",
         x = "2017",
         y = "Count") 
```

![](EDA_and_collaborative_filtering_files/figure-markdown_github/unnamed-chunk-9-1.png)

Generally, the number of unique users each week in this dataset distributes as indicated below. There was one particularly unusual week around May 14, where there was almost no user or click activity noted, as indicated by the graph above.

``` r
library(knitr)
weekly_activity %>%
  summarize(First_Quartile = quantile(unique_users, .25),
            median = median(unique_users),
            mean = mean(unique_users),
            Third_Quartile = quantile(unique_users, .75),
            Std_Deviation = sd(unique_users)
            ) %>%
  kable(caption = 'Typical Count of Unique Users by Week', align = 'c')
```

| First\_Quartile | median |   mean   | Third\_Quartile | Std\_Deviation |
|:---------------:|:------:|:--------:|:---------------:|:--------------:|
|     13347.75    |  14486 | 13853.88 |     15679.5     |    4092.181    |

The number of clicks by these unique users generally distributes as indicated by the table below. There was one particularly unusual week around May 14, where there was almost no user or click activity noted, as indicated by the graph above.

``` r
library(knitr)
weekly_activity %>%
  summarize(First_Quartile = quantile(total_clicks, .25),
            median = median(total_clicks),
            mean = mean(total_clicks),
            Third_Quartile = quantile(total_clicks, .75),
            Std_Deviation = sd(total_clicks)
            ) %>%
  kable(caption = 'Typical Count of total clicks by Week', align = 'c')
```

| First\_Quartile | median |   mean   | Third\_Quartile | Std\_Deviation |
|:---------------:|:------:|:--------:|:---------------:|:--------------:|
|     204798.2    | 287278 | 279252.3 |     361214.5    |     123685     |

### Description of Unique Visitors, PartNumbers, Parents

This was described before when defining the variables in the data, but I'll reiterate it here too. Initial analysis shows that there are 23997 unique VisitorID numbers in the entire dataset of randomly sampled user activity from 2017-01-31 through 2017-09-08.

There are 368374 unique PartNumbers associated with the visitor web activity data.

Instead of looking at very specific PartNumbers, we can also roll the analysis up to the Parent level, which was defined previously. There are 24058 unique Parent family numbers (referred herein as Parents) associated with the visitor web activity data.

Code for getting the aforementioned details is below.

``` r
# How many Different Users are in the dataset? 
unique(user_items$VisitorId) %>% length()
# How many distinct PartNumber's are in the dataset? 
unique(user_items$PartNumber) %>% length()
# How many distinct Parent Family's of PartNumbers are in the dataset? 
unique(user_items$Parent) %>% length()
```

### How do total Action Counts of each visitor distribute?

Action counts, as previously defined represent how often a visitor did a particular action within their session. In a single session (the day of the visitor activity interaction with a PartNumber) if they selected a PartNumber in the carousel, this is reflected as a single row in the dataset, with an ActionCount of 1. If they selected the part 2 times in this session, the ActionCount value is equal to 2.

``` r
user_items %>%
  group_by(VisitorId) %>%
  summarize(activity_count = sum(ActionCount)) %>%
  ggplot(aes(activity_count, y = ..density..)) + 
  geom_histogram(binwidth = 100, colour = "black", fill = "darkgrey") +
  # median vertical line.
  geom_vline(aes(xintercept = median(activity_count)),
             color = "black", linetype = "dashed", size = 0.5) +
  geom_text(aes(0,.0015, family = "courier", label = paste("median = ", median(activity_count))),
            nudge_x = 1500, color = "black", size = 4.5) +
  labs(title = 'Distribution of Total ActionCount by each Visitor',
       subtitle = 'binwidth of 100 ',
       x = "Total Actions per Visitor")
```

![](EDA_and_collaborative_filtering_files/figure-markdown_github/unnamed-chunk-13-1.png)

       Min. 1st Qu.  Median    Mean 3rd Qu.    Max. 
        1.0    99.0   263.0   426.7   559.0 10176.0 

After careful consideration, we have determined that total actions per PartNumber or per Parent within a single user session should not influence the implicit rating derived for the recommender. This could be for a variety of reasons, but primarily because there's not a strong theoretical basis that repeating an action in a single session with an item is an endorsement of that item. For example, selecting a part multiple times in the same session may perhaps be just as indicative of uncertainty or confusion as it could be of an interest in the item.

### How many unique PartNumbers is each visitor interacting with?

``` r
user_items %>%
  group_by(VisitorId) %>%
  distinct(PartNumber) %>% # only keep distinct part numbers per visitor.
  summarize(unique_part_count = n()) %>% # get count within the group. 
  ggplot(aes(unique_part_count, y = ..density..)) + 
  geom_histogram(binwidth = 100, colour = "darkgray", fill = "chartreuse3") +
  # median vertical line.
  geom_vline(aes(xintercept = median(unique_part_count)),
             color = "black", linetype = "dashed", size = 0.5) +
  geom_text(aes(0,.002, family = "courier", label = paste("median = ", median(unique_part_count))), 
            nudge_x = 600, color = "black", size = 4.5) +
  labs(title = 'Distribution of how many PartNumbers each Visitor interacted with',
       subtitle = 'binwidth of 100',
       x = 'Unique PartNumbers per Visitor')
```

![](EDA_and_collaborative_filtering_files/figure-markdown_github/unnamed-chunk-15-1.png)

       Min. 1st Qu.  Median    Mean 3rd Qu.    Max. 
        1.0    43.0   109.0   169.7   226.0  3847.0 

### How many unique Parents are visitors interacting with?

Instead of looking at the distinct PartNumbers that each visitor interacts with, we can also look at the Parent category that each PartNumber rolls up to. By reducing the diversity of different products from the specific PartNumber to the Parent category they roll up to, we'd expect the count of interactions with unique Parents to decrease. However, this may improve the sparsity problem of a recommender system.

``` r
user_items %>%
  group_by(VisitorId) %>%
  distinct(Parent) %>% # only keep distinct parent per visitor.
  summarize(unique_parent_count = n()) %>% # get count within the group. 
  ggplot(aes(unique_parent_count, y = ..density..)) + 
  geom_histogram(binwidth = 50, colour = "darkgray", fill = "cadetblue3") +
  # median vertical line.
  geom_vline(aes(xintercept = median(unique_parent_count)),
             color = "black", linetype = "dashed", size = 0.5) +
  geom_text(aes(0,.004, family = "courier", label = paste("median = ", median(unique_parent_count))), 
            nudge_x = 300, color = "black", size = 4.5) +
  labs(title = 'Distribution of how many Parent categories each Visitor interacted with',
       subtitle = 'binwidth of 50',
       x = 'Unique Parent category per Visitor')
```

![](EDA_and_collaborative_filtering_files/figure-markdown_github/unnamed-chunk-17-1.png)

       Min. 1st Qu.  Median    Mean 3rd Qu.    Max. 
        1.0    30.0    74.0   105.9   146.0  1798.0 

### How many unique visitors have interacted with each PartNumber?

The following summary stats distribution is potentially problematic. We have a very high dimensional dataset (more PartNumbers than users). So while each user appears to be interacting with quite a few PartNumbers as indicated by previous graphs, this graph shows that for any given PartNumber, there are typically only a handful of different visitors who have explored the exact same PartNumber.

``` r
user_items %>%
  group_by(PartNumber) %>%
  distinct(VisitorId) %>% # only keep distinct visitors per Item.
  summarize(unique_users_count = n()) %>%
  mutate(unique_users_count_max500 = ifelse(unique_users_count > 500, 500, unique_users_count)) %>%
  ggplot(aes(unique_users_count_max500, y = ..density..)) + # modal value is around log(2) or 2 items.
  geom_histogram(binwidth = 10, colour = "darkgray", fill = "orangered1") +
  # median vertical line.
  geom_vline(aes(xintercept = median(unique_users_count)),
             color = "black", linetype = "dashed", size = 0.5) +
  geom_text(aes(0,.04, family = "courier", label = paste("median = ", median(unique_users_count))), 
            nudge_x = 60, color = "black", size = 4.5) +
  labs(title = 'Distribution of Unique Visitors for each PartNumber',
       subtitle = 'binwidth of 10',
       x = 'Unique Visitors per PartNumber (upper limit coerced to 500)')
```

![](EDA_and_collaborative_filtering_files/figure-markdown_github/unnamed-chunk-19-1.png)

       Min. 1st Qu.  Median    Mean 3rd Qu.    Max. 
       1.00    2.00    5.00   11.06   11.00 1893.00 

Typically, on median, there are 5 unique visitors who've visited the same specific PartNumber, for the 368374 PartNumber categories.

### How many unique visitors have interacted with each Parent Family?

Because Parent Family's are a broader generalization than PartNumbers, we expect to have more interactions within a single Parent Family by multiple users than at the very specific PartNumber level. The summary statistics and distributions provided below reflect that when the dimensionality of the items is rolled up from the granular PartNumber level to the more general Parent category, we get more users who have looked at the same item.

``` r
user_items %>%
  group_by(Parent) %>%
  distinct(VisitorId) %>% # only keep distinct visitors per Item.
  summarize(unique_users_count = n()) %>%
  mutate(unique_users_count_max2000 = ifelse(unique_users_count > 2000, 2000, unique_users_count)) %>%
  ggplot(aes(unique_users_count_max2000, y = ..density..)) + 
  geom_histogram(binwidth = 50, colour = "darkgray", fill = "orchid") +
  # median vertical line.
  geom_vline(aes(xintercept = median(unique_users_count)),
             color = "black", linetype = "dashed", size = 0.5) +
  geom_text(aes(0, .005, family = "courier", label = paste("median = ", median(unique_users_count))),
            nudge_x = 300, color = "black", size = 4.5) +
  labs(title = 'Distribution of Unique Visitors for each Parent Family',
       subtitle = 'binwidth of 50',
       x = 'Unique Visitors per PartNumber (upper limit coerced to 2000)')
```

![](EDA_and_collaborative_filtering_files/figure-markdown_github/unnamed-chunk-21-1.png)

       Min. 1st Qu.  Median    Mean 3rd Qu.    Max. 
       1.00   18.00   41.00  105.62   99.75 7063.00 

Typically, on median, there are 41 unique visitors who've visited the same Parent category, of the 24058 Parent categories.

This is 8.2 times more unique visitors per item when looking at items from the Parent category perspective than at the most granular PartNumber perspective. Perhaps it may make more sense to model recommendations at the Parent level instead of at the PartNumber level, given these differences in how many unique users are looking at identical PartNumbers versus identical Parent categories.

However, we see a bit of a presence of fat tail. The max number of unique visitors per Parent category is 7063, which means that for at least 1 outlier parent category, 29% of unique users have interacted with the same product. This is very important in the collaborative filtering setting.

#### Impact of Long Tail Distributions

The previous 2 distributions of the frequency of number of users who rate PartNumbers and Parent categories, respectively both display a unique property common to recommender system problems. They have a very fat right-tail distribution. This means that most items available are rated infrequently by users and there are only a few commonly rated items, or "popular items".

According to [Aggarwal (2016)](https://www.amazon.com/Recommender-Systems-Textbook-Charu-Aggarwal/dp/3319296574), "The long tail distribution implies that the items, which are frequently rated by users are fewer in number. This fact has important implications for neighborhood-based collaborative filtering algorithms because neighborhoods are often defined on the basis of these frequently rated items. In many cases, the ratings of these high-frequency items are not representative of the low-frequency items because of inherent differences in the rating patterns of the two classes of items" (section 2.2).

Additionally, Aggarwal mentions that because some items are very popular across different users, "such ratings can sometimes worsen the quality of the recommendations becaues they tend to be less discriminative across different users. The negative impact of these recommendations can be experienced both during the peer group computation and also during the prediction computation" (section 2.3.1.4).

### How many PartNumbers fall into each Parent Family?

It's also interesting to know when we reduce the dimensionality of the products by rolling up from PartNumber to their parent categories, how many PartNumbers make up the Parent?

``` r
user_items %>%
  group_by(Parent) %>%
  distinct(PartNumber) %>% # remove duplicate part numbers within Parent Group. 
  summarize(unique_partnumber_count = n()) %>% # return count of unique items per parent. 
  with(summary(unique_partnumber_count))
```

       Min. 1st Qu.  Median    Mean 3rd Qu.    Max. 
       1.00    2.00    6.00   15.31   14.00  786.00 

### Do Parents with more PartNumbers also have more Visitors?

When we roll PartNumbers up to the parent level, the number of different users who interact with a Parent category may be a function of the tally of different PartNumbers that inheret from the Parent. If this is the case, we'd likely see a correlation between the frequency of PartNumbers per Parent and the number of unique visitors per Parent. Collaborative filtering methods are notorious for being biased by the the most popularly rated items, as those ratings will be a large influence in measuring inter-user similarity (user-based collaborative filtering) or inter-item similarity (item-based collaborative filtering).

![](EDA_and_collaborative_filtering_files/figure-markdown_github/unnamed-chunk-24-1.png)

However, this may be a necessary trade-off for these types of recommender systems as the more items in common that any pair of users have rated, the more robust the measures of similarity are, from which new recommendations can be made for items. For these algorithms to work well, it is important to adequately measure similar users or items, which is already difficult with very sparse matrices filled with primarily missing entries.

### What types of click Actions do the visitors take?

Below is the distribution of the 6 different click actions in the visitor click dataset of 8936075 different click actions.

``` r
# Bar graph of the 6 different Action ID Labels
user_items %>%
  group_by(ActionId, ActionId_label) %>%
  summarize(frequency = n()) %>%
  ggplot(aes(x = reorder(ActionId_label, desc(frequency)), y = frequency / sum(frequency))) +
    geom_bar(aes(fill = ActionId_label), stat = "identity") +
    labs(title = "Distribution of click Actions taken by Users",
         subtitle = "on company website",
         x = NULL,
         y = "Percent") +
    geom_text(aes(label = frequency, family = "courier", ), 
              size = 3,
              stat= "identity", 
              vjust = -.5) +
    guides(fill=FALSE) + # remove legend
    theme(axis.text.x=element_text(angle=25,hjust=1)) + # tilt x labels
    scale_y_continuous(labels=scales::percent)
```

![](EDA_and_collaborative_filtering_files/figure-markdown_github/unnamed-chunk-25-1.png)

|  ActionId| ActionId\_label          |  frequency|  proportion|
|---------:|:-------------------------|----------:|-----------:|
|         2| select Part              |    4429217|        0.50|
|         1| add to order             |    3242184|        0.36|
|         3| select Part detail       |    1068781|        0.12|
|         5| save CAD drawing detail  |     149957|        0.02|
|         4| print detail             |      29177|        0.00|
|         6| print CAD drawing detail |      16759|        0.00|

### (TO EXPLORE) What percent of the time is selecting a part a precursor to adding to cart?

If most of the clicks in the dataset reflect that generally, these ultimately lead to adding items to cart, perhaps this is some evidence that customers tend to know what they want when they land on the website. They aren't just querying the site or app out of general interest.

More Data Wrangling: Creating Ratings
-------------------------------------

Having explored information about the users and the items they've interacted with in the dataset, we need to devise a ratings system derived from user click actions. These user click actions are not explicit ratings but *inferred ratings* because the user is not telling us directly that they like this item. But, the actions themselves have a hierarchy that can be interpreted as different levels of interest, which may enable us to create "implicit ratings". In our company's case, a higher rating would correspond to which actions we would interpret to be closest to a purchase decision or showing a high level of interest.

This is generally a very popular way of devising ratings for ecommerce because most online interactions by web users aren't explicit ratings by users of a page or product, but simply interactions with that page or product.

### Convert Actions to Implicit Ratings

After consultation with Matt, the subject matter expert at the company, we decided to convert the values from the **ActionId** column into 3 distinct ratings. Specifically, the 6 different actions a user could take when interacting with distributed into a 1,2,3 ratings system from lowest to highest inferred rating.

-   Rating of 1 (low) = "select Part"

-   Rating of 2 = "select Part detail"

-   Rating of 3 (high) = "add to order", "print detail", "save CAD drawing detail", or "print CAD drawing detail"

These were coded into our dataset by creating a new variable called **action\_rating**, which was derived from the **ActionId\_label** of every user interaction.

``` r
user_items <- user_items %>%
  mutate(action_rating = if_else(ActionId_label == "select Part", 1, 
                                 if_else(ActionId_label == "select Part detail", 2, 3)))

user_items %>%
  group_by(action_rating) %>%
  summarize(frequency = n()) %>%
  ggplot(aes(x = action_rating, y = frequency / sum(frequency))) +
    geom_bar(aes(fill = desc(action_rating)), stat = "identity") +
    labs(title = "Distribution of Implicit Action Ratings taken by Users",
         subtitle = "on company website",
         x = NULL,
         y = "Percent",
         fill = "Implicit Rating") +
    geom_text(aes(label = frequency, family = "courier", ), 
              size = 3,
              stat= "identity", 
              vjust = -.5) +
    scale_y_continuous(labels=scales::percent)
```

![](EDA_and_collaborative_filtering_files/figure-markdown_github/unnamed-chunk-27-1.png)

|  ActionId| ActionId\_label          |  action\_rating|  frequency|  proportion|
|---------:|:-------------------------|---------------:|----------:|-----------:|
|         2| select Part              |               1|    4429217|        0.50|
|         1| add to order             |               3|    3242184|        0.36|
|         3| select Part detail       |               2|    1068781|        0.12|
|         5| save CAD drawing detail  |               3|     149957|        0.02|
|         4| print detail             |               3|      29177|        0.00|
|         6| print CAD drawing detail |               3|      16759|        0.00|

### Creating a weighted Total Rating per item

Having converted the 6 different possible actions into an implicit rating for each of the 8936075 individual user interactions in the user\_items dataset, there is still some more pre-processing required of these **action\_ratings**.

For this recommender system, recommendations of Parent categories were used instead of a specific PartNumber prediction problem. Doing this helps reduce the high dimensionality of the items, therefore reducing the sparsity problem of few users rating a single PartNumber. It also improves the computation time of the recommender system as there are fewer Parent categories to create predicted recommendations for relative to PartNumbers.

The weighted rating, which in its final form is called the total\_rating was derived in a series of steps:

-   **Step 1**: Within each visitor's session (ActionDate) with a Parent category, identify the maximum action\_rating the user gave to that Parent from its interaction.

    In the example below, Visitor \#1000368642442 interacted with Parent \#M65-364625 in three different sessions (2-22-2017, 6-14-2017, and 6-23-2017). Their interaction with Parent \#M65-365145 occurred in one session only on 6-7-2017.

| ActionDate |     VisitorId     |      Parent     |   PartNumber   |   ActionId   |  ActionId\_label  |                                      action\_rating                                      |
|:----------:|:-----------------:|:---------------:|:--------------:|:------------:|:-----------------:|:----------------------------------------------------------------------------------------:|
| 2017-06-23 |   1000368642442   |    M65-364625   |   M6557298085  |       2      |    select Part    |                                             1                                            |
| 2017-06-23 |   1000368642442   |    M65-364625   |   M6557298085  |       1      |    add to order   |                                             3                                            |
| 2017-06-23 |   1000368642442   |    M65-364625   |   M6557298095  |       1      |    add to order   |                                             3                                            |
| 2017-06-23 |   1000368642442   |    M65-364625   |   M6557298095  |       2      |    select Part    |                                             1                                            |
| 2017-06-14 |   1000368642442   |    M65-364625   |   M6557298105  |       1      |    add to order   |                                             3                                            |
| 2017-06-14 |   1000368642442   |    M65-364625   |   M6557298105  |       2      |    select Part    |                                             1                                            |
| 2017-06-14 |   1000368642442   |    M65-364625   |   M6557298115  |       1      |    add to order   |                                             3                                            |
| 2017-06-14 |   1000368642442   |    M65-364625   |   M6557298115  |       2      |    select Part    |                                             1                                            |
| 2017-02-22 |   1000368642442   |    M65-364625   |   M6557298185  |       1      |    add to order   |                                             3                                            |
| 2017-02-22 |   1000368642442   |    M65-364625   |   M6557298185  |       2      |    select Part    |                                             1                                            |
| 2017-06-07 |   1000368642442   |    M65-365145   |   M6556778115  |       1      |    add to order   |                                             3                                            |
| 2017-06-07 |   1000368642442   |    M65-365145   |   M6556778115  |       2      |    select Part    |                                             1                                            |
| For each o | f the sessions Vi | sitor \#1000368 | 642442 had per | table above, | we extract the ro | w of the max action\_rating it gave to each Parent category within the specific session. |

| ActionDate |   VisitorId   |   Parent   |  PartNumber | ActionId | ActionId\_label | action\_rating |
|:----------:|:-------------:|:----------:|:-----------:|:--------:|:---------------:|:--------------:|
| 2017-06-23 | 1000368642442 | M65-364625 | M6557298085 |     1    |   add to order  |        3       |
| 2017-06-23 | 1000368642442 | M65-364625 | M6557298095 |     1    |   add to order  |        3       |
| 2017-06-14 | 1000368642442 | M65-364625 | M6557298105 |     1    |   add to order  |        3       |
| 2017-06-14 | 1000368642442 | M65-364625 | M6557298115 |     1    |   add to order  |        3       |
| 2017-02-22 | 1000368642442 | M65-364625 | M6557298185 |     1    |   add to order  |        3       |
| 2017-06-07 | 1000368642442 | M65-365145 | M6556778115 |     1    |   add to order  |        3       |

-   **Step 2**: If there are multiple max action\_rating interactions per Parent within the same session (ex. the user did an "add to cart" action over multiple PartNumbers in a session, all inheriting from the same Parent category), we will sum these max action\_rating values up within that session to get a session\_action\_rating. The intuition here is that the more PartNumbers in a specific Parent category the user interacted with in a single session is a higher inferred endorsement of that Parent.

    Back to our example. Visitor \#1000368642442 did in fact interact with multiple different PartNumbers of the same Parent \#M65-364625 within a couple specific sessions (6-14-2017 and 6-23-2017). Hence multiple rows for those dates as illustrated above. Per the described weighting method, we sum up the max action\_rating values within the session (ActionDate) and Parent category to yield Visitor \#1000368642442's session\_action\_rating with a Parent.

|   VisitorId   |   Parent   | ActionDate | session\_action\_rating |
|:-------------:|:----------:|:----------:|:-----------------------:|
| 1000368642442 | M65-364625 | 2017-02-22 |            3            |
| 1000368642442 | M65-364625 | 2017-06-14 |            6            |
| 1000368642442 | M65-364625 | 2017-06-23 |            6            |
| 1000368642442 | M65-365145 | 2017-06-07 |            3            |

-   **Step 3**: Factor in the different number of sessions over time each user has engaged with each Parent category by adding up each user's maximum action\_rating for a Parent category across all their different sessions between 2017-01-31 and 2017-09-08.

    Back to our example for Visitor \#1000368642442. They have 3 different session\_action\_rating with Parent \#M65-364625. We will sum up their session\_action\_ratings to get a total\_rating of 15 for Parent \#M65-364625 For the other Parent \#M65-365145, this visitor only interacted with this during a single session, so it's total\_rating will equal its session\_actiong\_rating of 3.

|   VisitorId   |   Parent   | total\_rating |
|:-------------:|:----------:|:-------------:|
| 1000368642442 | M65-364625 |       15      |
| 1000368642442 | M65-365145 |       3       |

-   **Step 4**: After weighting the action\_rating per user for each Parent by considering diversity of the PartNumbers of a Parent they interacted with per session and the total number of sessions they interacted with the Parent over time, the ratings need to be transformed to reduce extreme outliers.

    For our example for Visitor \#1000368642442, the different total\_ratings could look something like this.

|   VisitorId   |   Parent   | total\_rating | total\_rating\_sqrt | total\_rating\_logn | total\_rating\_max10 |
|:-------------:|:----------:|:-------------:|:-------------------:|:-------------------:|:--------------------:|
| 1000368642442 | M65-364625 |       15      |       3.872983      |       2.708050      |          10          |
| 1000368642442 | M65-365145 |       3       |       1.732051      |       1.098612      |           3          |

The actual code for the preprocessing of Steps 1 through 4 proceeds below via use of a `dplyr` analysis pipeline:

``` r
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
  # Step4: ratings transformation candidates
  mutate(total_rating_sqrt = sqrt(total_rating),
         total_rating_logn = log(total_rating),
         total_rating_max10 = ifelse(total_rating > 10, 10, total_rating)) %>%
  arrange(VisitorId, total_rating)
```

### Different Scale Transformations for Total\_ratings

I came up with 3 initial different ways to transform the total\_rating per Parent category for every user to tighten the distribution of total\_ratings. The 3 other transformations are a lognormal transformation, square root transformation, and coercing the upper limit to a max value of 10.

``` r
tidy_ratings <- user_ratings %>%
  gather(key = rating_type, value = value, -VisitorId, -Parent)

tidy_ratings %>%
  ggplot(aes(value, fill = rating_type)) +
  geom_histogram(data = filter(tidy_ratings, rating_type == "total_rating"), binwidth = 20, color = "black") +
  geom_histogram(data = filter(tidy_ratings, rating_type != "total_rating"), binwidth = 1, color = "black") + 
  facet_wrap(~ rating_type, scales = "free") +
  labs(title = "Distribution of Visitors' Total Rating of Parent Part Families",
       subtitle = "with different scale transformations",
       x = NULL) +
  guides(fill = FALSE) +
  scale_y_continuous(labels = function(n) format(n, scientific = FALSE)) # raw frequency scale
```

![](EDA_and_collaborative_filtering_files/figure-markdown_github/unnamed-chunk-35-1.png)

``` r
remove(tidy_ratings)
```

      total_rating     total_rating_sqrt total_rating_logn total_rating_max10
     Min.   :  1.000   Min.   : 1.000    Min.   :0.000     Min.   : 1.000    
     1st Qu.:  3.000   1st Qu.: 1.732    1st Qu.:1.099     1st Qu.: 3.000    
     Median :  3.000   Median : 1.732    Median :1.099     Median : 3.000    
     Mean   :  4.745   Mean   : 1.984    Mean   :1.222     Mean   : 3.972    
     3rd Qu.:  6.000   3rd Qu.: 2.449    3rd Qu.:1.792     3rd Qu.: 6.000    
     Max.   :818.000   Max.   :28.601    Max.   :6.707     Max.   :10.000    

We can also look at the standard deviation for each of the 4 different total\_ratings too. Naturally, the raw total\_ratings will have the largest standardized variance b/c of its extreme right-skew. When applying a sqrt() or log() transformation, the total\_ratings preserve their rank order but we also see that the scores are much more scrunched together in the middle 50% range of values, or interquartile range (IQR), also reflected by their low standard deviation. The last option I tried was using a coercion method, such as capping the upper limit at a max total\_rating of 10. Doing so seems to balance keeping the scores in a reasonable range while allowing for variance between each Parent rating by each visitor, especially in the IQR. Total\_rating\_max10 will be what I use for these models going forward.

``` r
library(purrr)
map_dbl(user_ratings[3:6], sd) # get the standard deviation for each total_rating type.
```

          total_rating  total_rating_sqrt  total_rating_logn 
             6.8333019          0.8988195          0.7360477 
    total_rating_max10 
             2.5783076 

### Setting up a User Ratings Matrix

We're at the point now where we have a dataset where each row represents the total\_rating of a specific item (Parent) made by a specific VisitorID.

``` r
sample_n(user_ratings[,1:3], 10) %>%
  kable(align = 'c')
```

|   VisitorId   |   Parent   | total\_rating |
|:-------------:|:----------:|:-------------:|
|  647027980726 | P66-304060 |       3       |
| 1408747058923 | O65-465939 |       9       |
|  621451876059 | O67-464364 |       6       |
|  733740261545 | O66-493394 |       12      |
| 1124236964536 | P65-306717 |       3       |
|  612948177427 | M78-409515 |       2       |
|  726734131242 | O67-478224 |       2       |
|  803856000258 | M67-409095 |       1       |
| 8156451706107 | O66-465104 |       3       |
| 1333648509124 | N66-542027 |       3       |

These 3 components are all that is needed to craete a user-items rating matrix. The rows of the matrix will represent individual users, columns will represent the distinct Parent categories, and the elements in the matrix will represent the respective total\_rating of the item.

To make the storage of the matrix memory efficient, a sparse matrix will be used. A sparse matrix, using a package like `matrix` only fills the non-missing entries in the matrix, making them [very memory efficient](http://www.johnmyleswhite.com/notebook/2011/10/31/using-sparse-matrices-in-r/) for large matrix objects.

The row (i) and column (j) indices of a matrix need to be 1 starting index based. The easiest way to facilitate this while still being able to map the row and column labels is to coerce the VisitorId and Parent columns in our dataset to as.factor() and then to as.integer(). When coercing to a factor, the values will be alphabetically sorted by default. We can then pass dimension names to the row and columns of the matrix by passing the unique, sorted VisitorId and Parent labels. See code below for details.

``` r
library(Matrix)
# sparse ratings matrix.
# https://stackoverflow.com/questions/28430674/create-sparse-matrix-from-data-frame?noredirect=1&lq=1
# the VisitorId and Parent need to be 1 based indices when creating a matrix. 
# Per ?factor, the levels of a factor are by default sorted.
sparse_r <- sparseMatrix(i = as.integer(as.factor(user_ratings$VisitorId)), 
                         j = as.integer(as.factor(user_ratings$Parent)),
                         x = user_ratings$total_rating_max10)

# can rename the matrix row and column labels with unique VisitorId and Parent names. 
dimnames(sparse_r) <- list(sort(unique(user_ratings$VisitorId)),
                           sort(unique(user_ratings$Parent)))
```

We can check that the levels of the coerced factor are identical name position matches to the dimnames that we passed as labels to the rows and columns of the sparse matrix.

``` r
all.equal(levels(as.factor(user_ratings$VisitorId)), 
          sort(unique(user_ratings$VisitorId))) 
```

    [1] TRUE

``` r
all.equal(levels(as.factor(user_ratings$Parent)), 
          sort(unique(user_ratings$Parent))) 
```

    [1] TRUE

``` r
# class(sparse_r)
# dim(sparse_r)
# attributes(sparse_r)
# str(sparse_r) # it's an S4 object. use slots (@) to access elements. 
```

Collaborative Filtering Algorithms
----------------------------------

According to Aggawal (2016), collaborative filtering models use the "power of the ratings provided by multiple users to make recommendations" (1.3.1). By finding out how users are similar to each other based on how they may rate the same items in a correlated way, or how items may be rated in a correlated way across different users, an algorithm can leverage these correlations or measures of similarity as the basis to predict and recommend new items not yet rated by an indvidual.

For collaborative filtering recommender systems, the recommendations are largely based on the ability to identify recommendations by

-   1.  finding similar users who've rated the same items similarly to me. This method addresses a recommendation hypothesis of "what other users are like me, and what items do they purchase?" This is known as **user-based collaborative filtering**. It finds users who have similar interest in items as you and recommends new items based on a weighted formula of what they rate highly that you haven't yet looked at or purchased.

-   1.  We can also make recommendations by finding items that are similarly rated to the ones that a user has rated. In this case, neighborhoods are defined not by similar users but by items with similar ratings pattern across users. These item similarity measures are then compared to the items the user has already rated. This is known as **item-based collaborative filtering**. It addresses a recommendation hypothesis of "people who liked this also tend to like this" or "What items are most similar to the ones that I’ve purchased that may interest me?"

User Based Collaborative Filtering
----------------------------------

Item Based Collaborative Filtering
----------------------------------