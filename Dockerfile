FROM ruby:2.2

WORKDIR /usr/src/app

COPY Gemfile mega_mutex.gemspec ./
RUN bundle install

COPY . .
