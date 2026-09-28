ARG RUBY_VERSION=4.0.6
FROM ruby:${RUBY_VERSION}-slim AS base

WORKDIR /app

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      build-essential \
      git \
      libpq-dev \
      libyaml-dev \
      pkg-config && \
    rm -rf /var/lib/apt/lists/*

ENV BUNDLE_PATH=/usr/local/bundle

FROM base AS development

EXPOSE 8083

CMD ["bundle", "exec", "puma", "-C", "config/puma.rb", "-p", "8083"]
