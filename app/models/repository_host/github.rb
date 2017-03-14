module RepositoryHost
  class Github < Base
    IGNORABLE_EXCEPTIONS = [Octokit::Unauthorized, Octokit::InvalidRepository, Octokit::RepositoryUnavailable, Octokit::NotFound, Octokit::Conflict, Octokit::Forbidden, Octokit::InternalServerError, Octokit::BadGateway, Octokit::ClientError]

    def avatar_url(size = 60)
      "https://avatars.githubusercontent.com/u/#{repository.owner_id}?size=#{size}"
    end

    def domain
      'https://github.com'
    end

    def watchers_url
      "#{url}/watchers"
    end

    def forks_url
      "#{url}/network"
    end

    def stargazers_url
      "#{url}/stargazers"
    end

    def contributors_url
      "#{url}/graphs/contributors"
    end

    def blob_url(sha = nil)
      sha ||= repository.default_branch
      "#{url}/blob/#{sha}/"
    end

    def commits_url(author = nil)
      author_param = author.present? ? "?author=#{author}" : ''
      "#{url}/commits#{author_param}"
    end

    def self.fetch_repo(full_name, token = nil)
      AuthToken.fallback_client(token).repo(full_name, accept: 'application/vnd.github.drax-preview+json').to_hash
    rescue *IGNORABLE_EXCEPTIONS
      nil
    end

    def get_file_list(token = nil)
      tree = api_client(token).tree(repository.full_name, repository.default_branch, :recursive => true).tree
      tree.select{|item| item.type == 'blob' }.map{|file| file.path }
    rescue *IGNORABLE_EXCEPTIONS
      nil
    end

    def get_file_contents(path, token = nil)
      file = api_client(token).contents(repository.full_name, path: path)
      {
        sha: file.sha,
        content: file.content.present? ? Base64.decode64(file.content) : file.content
      }
    rescue *IGNORABLE_EXCEPTIONS
      nil
    end

    def create_webhook(token = nil)
      api_client(token).create_hook(
        repository.full_name,
        'web',
        {
          :url => 'https://libraries.io/hooks/github',
          :content_type => 'json'
        },
        {
          :events => ['push', 'pull_request'],
          :active => true
        }
      )
    rescue Octokit::UnprocessableEntity
      nil
    end

    def download_contributions(token = nil)
      gh_contributions = api_client(token).contributors(repository.full_name)
      return if gh_contributions.empty?
      existing_contributions = repository.contributions.includes(:github_user).to_a
      platform = repository.projects.first.try(:platform)
      gh_contributions.each do |c|
        next unless c['id']
        cont = existing_contributions.find{|cnt| cnt.github_user.try(:github_id) == c.id }
        unless cont
          user = GithubUser.create_from_github(c)
          cont = repository.contributions.find_or_create_by(github_user: user)
        end

        cont.count = c.contributions
        cont.platform = platform
        cont.save! if cont.changed?
      end
      true
    rescue *IGNORABLE_EXCEPTIONS
      nil
    end

    def download_forks(token = nil)
      return true if repository.fork?
      return true unless repository.forks_count && repository.forks_count > 0 && repository.forks_count < 100
      return true if repository.forks_count == repository.forked_repositories.host(repository.host_type).count
      AuthToken.new_client(token).forks(repository.full_name).each do |fork|
        Repository.create_from_hash(fork)
      end
    end

    def download_issues(token = nil)
      api_client = AuthToken.new_client(token)
      issues = api_client.issues(repository.full_name, state: 'all')
      issues.each do |issue|
        Issue.create_from_hash(repository, issue)
      end
    rescue *IGNORABLE_EXCEPTIONS
      nil
    end

    def download_owner
      return if repository.owner && repository.owner.login == repository.owner_name
      o = api_client.user(repository.owner_name)
      if o.type == "Organization"
        go = GithubOrganisation.create_from_github(repository.owner_id.to_i)
        if go
          repository.github_organisation_id = go.id
          repository.save
        end
      else
        GithubUser.create_from_github(o)
      end
    rescue *IGNORABLE_EXCEPTIONS
      nil
    end

    def download_readme(token = nil)
      contents = {
        html_body: api_client(token).readme(repository.full_name, accept: 'application/vnd.github.V3.html')
      }

      if repository.readme.nil?
        repository.create_readme(contents)
      else
        repository.readme.update_attributes(contents)
      end
    rescue *IGNORABLE_EXCEPTIONS
      nil
    end

    def download_tags(token = nil)
      existing_tag_names = repository.tags.pluck(:name)
      tags = api_client(token).refs(repository.full_name, 'tags')
      Array(tags).each do |tag|
        next unless tag && tag.is_a?(Sawyer::Resource) && tag['ref']
        download_tag(token, tag, existing_tag_names)
      end
    rescue *IGNORABLE_EXCEPTIONS
      nil
    end

    def download_tag(token, tag, existing_tag_names)
      match = tag.ref.match(/refs\/tags\/(.*)/)
      return unless match
      name = match[1]
      return if existing_tag_names.include?(name)

      object = api_client(token).get(tag.object.url)

      tag_hash = {
        name: name,
        kind: tag.object.type,
        sha: tag.object.sha
      }

      case tag.object.type
      when 'commit'
        tag_hash[:published_at] = object.committer.date
      when 'tag'
        tag_hash[:published_at] = object.tagger.date
      end

      repository.tags.create!(tag_hash)
    end

    def update(token = nil)
      begin
        r = self.class.fetch_repo(repository.id_or_name)
        return unless r.present?
        repository.uuid = r[:id] unless repository.uuid == r[:id]
         if repository.full_name.downcase != r[:full_name].downcase
           clash = Repository.host('GitHub').where('lower(full_name) = ?', r[:full_name].downcase).first
           if clash && (!clash.update(token) || clash.status == "Removed")
             clash.destroy
           end
           repository.full_name = r[:full_name]
         end
        repository.owner_id = r[:owner][:id]
        repository.license = Project.format_license(r[:license][:key]) if r[:license]
        repository.source_name = r[:parent][:full_name] if r[:fork]
        repository.assign_attributes r.slice(*API_FIELDS)
        repository.save! if repository.changed?
      rescue Octokit::NotFound
        repository.update_attribute(:status, 'Removed') if !repository.private?
      rescue *IGNORABLE_EXCEPTIONS
        nil
      end
    end

    private

    def api_client(token = nil)
      AuthToken.fallback_client(token)
    end
  end
end
