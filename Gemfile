source "https://rubygems.org"

gemspec

# Not in the image (deploy/vps/Dockerfile: BUNDLE_WITHOUT=development:test).
group :development, :test do
  gem "rake", ">= 13"
  gem "minitest", ">= 5.25"
end
