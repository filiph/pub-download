# pub_download

A simple scraper of pub.dartlang.org.

Install like this:

```
$ pub get && pub run sqlite:install --package-root .
```

Then run for the first time like this:

```
$ dart bin/fetch.dart first-run
```

And afterwards, run this periodically (through cron, likely)

```
$ dart bin/fetch.dart
```
