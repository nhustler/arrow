# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

context("Datasets")

library(dplyr)

dataset_dir <- tempfile()
dir.create(dataset_dir)

hive_dir <- tempfile()
dir.create(hive_dir)

first_date <- lubridate::ymd_hms("2015-04-29 03:12:39")
df1 <- tibble(
  int = 1:10,
  dbl = as.numeric(1:10),
  lgl = rep(c(TRUE, FALSE, NA, TRUE, FALSE), 2),
  chr = letters[1:10],
  fct = factor(LETTERS[1:10]),
  ts = first_date + lubridate::days(1:10)
)

second_date <- lubridate::ymd_hms("2017-03-09 07:01:02")
df2 <- tibble(
  int = 101:110,
  dbl = as.numeric(51:60),
  lgl = rep(c(TRUE, FALSE, NA, TRUE, FALSE), 2),
  chr = letters[10:1],
  fct = factor(LETTERS[10:1]),
  ts = second_date + lubridate::days(10:1)
)

test_that("Setup (putting data in the dir)", {
  dir.create(file.path(dataset_dir, 1))
  dir.create(file.path(dataset_dir, 2))
  write_parquet(df1, file.path(dataset_dir, 1, "file1.parquet"))
  write_parquet(df2, file.path(dataset_dir, 2, "file2.parquet"))
  expect_length(dir(dataset_dir, recursive = TRUE), 2)

  dir.create(file.path(hive_dir, "subdir", "group=1", "other=xxx"), recursive = TRUE)
  dir.create(file.path(hive_dir, "subdir", "group=2", "other=yyy"), recursive = TRUE)
  write_parquet(df1, file.path(hive_dir, "subdir", "group=1", "other=xxx", "file1.parquet"))
  write_parquet(df2, file.path(hive_dir, "subdir", "group=2", "other=yyy", "file2.parquet"))
  expect_length(dir(hive_dir, recursive = TRUE), 2)
})

test_that("Simple interface for datasets", {
  ds <- open_dataset(dataset_dir, partition = schema(part = uint8()))
  expect_is(ds, "Dataset")
  expect_equivalent(
    ds %>%
      select(chr, dbl) %>%
      filter(dbl > 7 & dbl < 53L) %>% # Testing the auto-casting of scalars
      arrange(dbl),
    rbind(
      df1[8:10, c("chr", "dbl")],
      df2[1:2, c("chr", "dbl")]
    )
  )

  expect_equivalent(
    ds %>%
      select(string = chr, integer = int, part) %>%
      filter(integer > 6 & part == 1) %>% # 6 not 6L to test autocasting
      summarize(mean = mean(integer)),
    df1 %>%
      select(string = chr, integer = int) %>%
      filter(integer > 6) %>%
      summarize(mean = mean(integer))
  )
})

test_that("Hive partitioning", {
  ds <- open_dataset(hive_dir, partition = hive_partition(other = utf8(), group = uint8()))
  expect_is(ds, "Dataset")
  expect_equivalent(
    ds %>%
      filter(group == 2) %>%
      select(chr, dbl) %>%
      filter(dbl > 7 & dbl < 53) %>%
      arrange(dbl),
    df2[1:2, c("chr", "dbl")]
  )
})

test_that("Partition scheme inference", {
  # These are the same tests as above, just using the *PartitionSchemeDiscovery
  ds1 <- open_dataset(dataset_dir, partition = "part")
  expect_identical(names(ds1), c(names(df1), "part"))
  expect_equivalent(
    ds1 %>%
      select(string = chr, integer = int, part) %>%
      filter(integer > 6 & part == 1) %>%
      summarize(mean = mean(integer)),
    df1 %>%
      select(string = chr, integer = int) %>%
      filter(integer > 6) %>%
      summarize(mean = mean(integer))
  )

  ds2 <- open_dataset(hive_dir)
  expect_identical(names(ds2), c(names(df1), "group", "other"))
  print(ds2$schema)
  expect_equivalent(
    ds2 %>%
      filter(group == 2) %>%
      select(chr, dbl) %>%
      filter(dbl > 7 & dbl < 53) %>%
      arrange(dbl),
    df2[1:2, c("chr", "dbl")]
  )
})

test_that("filter() on a dataset won't auto-collect", {
  ds <- open_dataset(dataset_dir, partition = "part")
  expect_error(
    ds %>% filter(int > 6, dbl > max(dbl)),
    "Filter expression not supported for Arrow Datasets: dbl > max(dbl)",
    fixed = TRUE
  )
})

test_that("filter() with is.na()", {
  ds <- open_dataset(dataset_dir, partition = schema(part = uint8()))
  expect_equivalent(
    ds %>%
      select(part, lgl) %>%
      filter(!is.na(lgl), part == 1) %>%
      collect(),
    tibble(part = 1L, lgl = df1$lgl[!is.na(df1$lgl)])
  )
})

test_that("filter() with %in%", {
  ds <- open_dataset(dataset_dir, partition = schema(part = uint8()))
  expect_equivalent(
    ds %>%
      select(int, part) %>%
      filter(int %in% c(6L, 4L, 3L, 103L, 107L), part == 1) %>%
      # TODO: C++ In() should cast: ARROW-7204
      collect(),
    tibble(int = df1$int[c(3, 4, 6)], part = 1)
  )
})

test_that("filter() on timestamp columns", {
  ds <- open_dataset(dataset_dir, partition = schema(part = uint8()))
  datetime_to_ns <- function (x) {
    # TODO: src/expression.cpp should handle timestamp data
    # TODO: C++ library should handle autocasting
    as.numeric(x) * 1000000
  }
  expect_equivalent(
    ds %>%
      filter(ts >= datetime_to_ns(lubridate::ymd_hms("2015-05-04 03:12:39"))) %>%
      filter(part == 1) %>%
      select(ts) %>%
      collect(),
    df1[5:10, c("ts")],
  )
})

test_that("Assembling a Dataset manually and getting a Table", {
  fs <- LocalFileSystem$create()
  selector <- FileSelector$create(dataset_dir, recursive = TRUE)
  partition <- SchemaPartitionScheme$create(schema(part = double()))

  dsd <- FileSystemDataSourceDiscovery$create(fs, selector, partition_scheme = partition)
  expect_is(dsd, "FileSystemDataSourceDiscovery")

  schm <- dsd$Inspect()
  expect_is(schm, "Schema")

  phys_schm <- ParquetFileReader$create(file.path(dataset_dir, 1, "file1.parquet"))$GetSchema()
  expect_equal(names(phys_schm), names(df1))
  expect_equal(names(schm), c(names(phys_schm), "part"))

  datasource <- dsd$Finish(schm)
  expect_is(datasource, "DataSource")

  ds <- Dataset$create(list(datasource), schm)
  expect_is(ds, "Dataset")
  expect_equal(names(ds), names(schm))

  sb <- ds$NewScan()
  expect_is(sb, "ScannerBuilder")
  expect_equal(sb$schema, schm)

  sb$Project(c("chr", "lgl"))
  sb$Filter(FieldExpression$create("dbl") == 8)
  scn <- sb$Finish()
  expect_is(scn, "Scanner")

  tab <- scn$ToTable()
  expect_is(tab, "Table")

  expect_equivalent(
    as.data.frame(tab),
    df1[8, c("chr", "lgl")]
  )
})
