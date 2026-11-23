#!/usr/bin/env ruby
# Gathers what the cybertrain-release skill needs before a release, as JSON:
# the previous release tag, the pull requests merged into main since it (with
# the title the merge commit carries, when it carries one), the "Compatibility"
# paragraphs docs/design.md gained since the tag, the release sections of the
# upgrading guide and its translations, the numbers main pins now
# (Cybertrain::VERSION, SPINEL_TAG, SPINEL_REPOSITORY), the Spinel fork's
# newest tags, and whether the Spinel candidate and Bump version workflows are
# on main. Standard library only; reads git, never writes.
#
# usage: ruby .claude/skills/cybertrain-release/scripts/release-status.rb [--no-fetch]
#   --no-fetch   use the local refs as they are (default: fetch origin main and tags first)
require "json"
require "open3"

Encoding.default_external = Encoding::UTF_8

def git(*args)
  out, status = Open3.capture2("git", *args)
  status.success? ? out.force_encoding(Encoding::UTF_8) : nil
end

def tag_key(tag)
  tag.sub(/\Av/, "").split(".").map(&:to_i)
end

root = git("rev-parse", "--show-toplevel")&.strip or abort "release-status: not in a git checkout"
Dir.chdir(root)

warnings = []
unless ARGV.include?("--no-fetch")
  git("fetch", "--quiet", "--tags", "origin", "main") or warnings << "git fetch origin main failed; local refs may be stale"
end

main_ref = git("rev-parse", "--verify", "--quiet", "origin/main") ? "origin/main" : "HEAD"
main_sha = git("rev-parse", main_ref).strip

# Release tags are vX.Y.Z; the newest by number, not by date.
release_tags = (git("tag", "--list", "v*") || "").split.grep(/\Av\d+\.\d+\.\d+\z/).sort_by { |t| tag_key(t) }
last_tag = release_tags.last
last_tag_date = last_tag && git("log", "-1", "--format=%cI", last_tag)&.strip

# Pull requests merged since the tag: merge commits on main's first-parent line
# ("Merge pull request #N from ...") and squash merges ("Title (#N)").
range = last_tag ? "#{last_tag}..#{main_ref}" : main_ref
prs = []
# A merge commit's body starts with the pull request's title, unless the
# merge left it empty; those numbers go to prs_without_title.
(git("log", "--first-parent", "--format=%H%x09%s%x09%b%x00", range) || "").split("\0").each do |entry|
  sha, subject, body = entry.strip.split("\t", 3)
  next if sha.nil? || subject.nil?
  if (m = subject.match(/\AMerge pull request #(\d+) from (\S+)/))
    title = body.to_s.lines.map(&:strip).find { |l| !l.empty? }
    pr = { "number" => m[1].to_i, "branch" => m[2], "commit" => sha[0, 12] }
    pr["title"] = title if title
    prs << pr
  elsif (m = subject.match(/\(#(\d+)\)\z/))
    prs << { "number" => m[1].to_i, "title" => subject.sub(/\s*\(#\d+\)\z/, ""), "commit" => sha[0, 12] }
  end
end
direct = (git("log", "--first-parent", "--format=%s", range) || "").lines.reject { |s| s =~ /\AMerge pull request #\d+|\(#\d+\)\s*\z/ }.map(&:strip)

prs_without_title = prs.reject { |pr| pr["title"] }.map { |pr| pr["number"] }

# "- Compatibility" paragraphs of docs/design.md added since the tag, each
# with the decision heading (### Dnn.) above it on main.
compat = []
if last_tag && (design = git("show", "#{main_ref}:docs/design.md"))
  added = (git("diff", "#{last_tag}..#{main_ref}", "--", "docs/design.md") || "").lines
          .select { |l| l.start_with?("+") && !l.start_with?("+++") }.map { |l| l[1..].rstrip }
  heading = nil
  design.each_line do |line|
    heading = line.strip.sub(/\A#+\s*/, "") if line =~ /\A###\s+D\d+\./
    next unless line =~ /\A\s*- Compatibility/ && added.include?(line.rstrip)
    compat << { "decision" => heading, "text" => line.strip[0, 300] }
  end
end

# The release sections ("## From 0.4 to 0.5", "## 0.4 から 0.5 へ", ...) of the
# upgrading guide and its translations.
upgrading = {}
(git("ls-tree", "-r", "--name-only", main_ref, "docs/guide") || "").split.grep(%r{(\A|/)upgrading\.md\z}).sort.each do |path|
  text = git("show", "#{main_ref}:#{path}") or next
  upgrading[path] = text.lines.grep(/\A##\s.*\d+\.\d+/).map { |l| l.strip.sub(/\A##\s*/, "") }
end

version_rb = git("show", "#{main_ref}:cybertrain/version.rb") || File.read("cybertrain/version.rb")
version = version_rb[/^\s*VERSION = "([^"]+)"/, 1]
spinel_tag = version_rb[/^\s*SPINEL_TAG = "([^"]+)"/, 1]
spinel_repo = version_rb[/^\s*SPINEL_REPOSITORY = "([^"]+)"/, 1]

spinel_tags = []
if spinel_repo
  out = git("ls-remote", "--tags", spinel_repo)
  if out
    spinel_tags = out.lines.map { |l| l.split("\t")[1].to_s.strip.sub("refs/tags/", "") }
                     .reject { |t| t.end_with?("^{}") || t.empty? }
                     .grep(/\A\d{4}\.\d{2}\.\d{2}(\.\d+)?\z/)
                     .sort_by { |t| tag_key(t) }
  else
    warnings << "git ls-remote #{spinel_repo} failed; Spinel tags unknown"
  end
end
latest_spinel = spinel_tags.last
newer_spinel = spinel_tag ? spinel_tags.select { |t| (tag_key(t) <=> tag_key(spinel_tag)) == 1 } : []

workflows = (git("ls-tree", "--name-only", "#{main_ref}:.github/workflows") || "").split

puts JSON.pretty_generate(
  "main" => { "ref" => main_ref, "sha" => main_sha },
  "last_release" => { "tag" => last_tag, "date" => last_tag_date },
  "already_released" => last_tag && git("rev-parse", "#{last_tag}^{commit}")&.strip == main_sha,
  "merged_prs" => prs,
  "merged_pr_count" => prs.size,
  "prs_without_title" => prs_without_title,
  "direct_commits_on_main" => direct,
  "compatibility_paragraphs_since_tag" => compat,
  "upgrading_sections" => upgrading,
  "pins" => { "version" => version, "spinel_tag" => spinel_tag, "spinel_repository" => spinel_repo },
  "spinel" => {
    "latest_tag" => latest_spinel,
    "newer_than_pin" => newer_spinel,
    "pin_is_latest" => !latest_spinel.nil? && latest_spinel == spinel_tag
  },
  "workflows_on_main" => {
    "spinel_candidate" => workflows.include?("spinel-candidate.yml"),
    "bump_version" => workflows.include?("bump-version.yml")
  },
  "warnings" => warnings
)
