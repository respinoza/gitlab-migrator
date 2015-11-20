module Fastlane
  module Actions
    module SharedValues
    end

    require 'gitlab'

    class GitlabCreateProjectAction < Action
      def self.run(params)
        source = Gitlab.client(endpoint: params[:endpoint_src], private_token: params[:api_token_src])
        destination = Gitlab.client(endpoint: params[:endpoint_dst], private_token: params[:api_token_dst])
        original_project = params[:project]
        Helper.log.info "Creating Project: #{original_project.path_with_namespace}"

        # Check if the Group and Namespace for the Project exist already
        group = ensure_group(destination, original_project.namespace.name, original_project.namespace.path)

        # Create the project
        new_project = destination.create_project(original_project.name,
          description: original_project.description,
          default_branch: original_project.default_branch,
          group_id: group.id,
          namespace_id: group.id,
          wiki_enabled: original_project.wiki_enabled,
          wall_enabled: original_project.wall_enabled,
          issues_enabled: original_project.issues_enabled,
          snippets_enabled: original_project.snippets_enabled,
          merge_requests_enabled: original_project.merge_reques,
          public: original_project.public
        )

        Helper.log.info("New Project created with ID: #{new_project.id} -  #{new_project}")

        # Estimate User-Mapping
        user_mapping = map_users(source, destination)

        # Create Labels
        migrate_labels(source, destination, original_project, new_project)

        # Create Milestones
        milestone_mapping = migrate_milestones(source, destination, original_project, new_project)

        # Create Issues
        migrate_issues(source, destination, original_project, new_project, user_mapping, milestone_mapping)

        new_project
      end

      # Given a group (with path-name) from the original project, 
      # checks if a group with the same path-name exists in the destination gitlab.
      # If necessary, a group with that path-name is created
      # The group (in the destination gitlab) is returned
      def self.ensure_group(client, group_name, group_path)
        Helper.log.info("Searching for group with name '#{group_name}' and path: '#{group_path}'")
        group = read_groups(client).select { |g| g.path == group_path}.first
        if group
          Helper.log.info("Existing group '#{group.name}' found")
        else
          Helper.log.info("Group '#{group_name}' does not yet exist, will be created now")
          group = client.create_group(group_name, group_path)
        end
        group
      end

      # Reads all users from the source gitlab and sees if there is an existing user (with the same name)
      # in the new gitlab. If so, an entrie to map the old id to the new id is inserted into the user map
      def self.map_users(gitlab_src, gitlab_dst)
        users_src = read_users(gitlab_src)
        users_dst = read_users(gitlab_dst)

        user_map = {}
        users_src.each do |user|
          users = users_dst.select { |u| u.username == user.username or u.name == user.name}
          if users.count == 1
            # Only map users that are unambiguously the same. If there are several matches, dont match them
            Helper.log.info("Mapping user #{user.username} to #{users.first.username}: #{user.id}=#{users.first.id}")
            user_map[user.id] = users.first.id
          end
        end
        Helper.log.info("User Mapping determined: #{user_map}")
        user_map
      end

      # Reads all labels from the source project and create them in the destination project
      # Labels are later referenced by name, so we dont need to return an ID-Mapping
      def self.migrate_labels(gitlab_src, gitlab_dst, project_src, project_dst)
        Helper.log.info("Creating Labels")
        labels = gitlab_src.labels(project_src.id)

        labels.each do |label| 
          gitlab_dst.create_label(project_dst.id, label.name, label.color)
        end
        Helper.log.info("Labels created")
      end

      # Reads all milestones from the source project and create them in the destination project
      # Milestones are later referenced by ID, so we need to return a mapping from milestone-id in the old project to milestone-id in the new project
      def self.migrate_milestones(gitlab_src, gitlab_dst, project_src, project_dst) 
        Helper.log.info("Migrating Milestones")
        milestone_map = {}
        read_milestones(gitlab_src, project_src).each do |milestone|
          new_milestone = gitlab_dst.create_milestone(project_dst.id, 
            milestone.title,
            description: milestone.description,
            due_date: milestone.due_date
            )
          if milestone.state == "closed"
            gitlab_dst.edit_milestone(project_dst.id, new_milestone.id, state_event: "close")
          end
          milestone_map[milestone.id] = new_milestone.id
        end
        Helper.log.info("Milestones migrated, milestone map generated: #{milestone_map}")
        milestone_map
      end

      def self.migrate_issues(gitlab_src, gitlab_dst, project_src, project_dst, usermap, milestonemap)
        Helper.log.info("Creating Issues")

        Helper.log.info("Usermap: #{usermap}")
        Helper.log.info("Milestonemap: #{milestonemap}")

        read_issues(gitlab_src, project_src).each do |issue|

          assignee_id = usermap[issue.assignee.id] if issue.assignee
          milestone_id = milestonemap[issue.milestone.id] if issue.milestone
          new_issue = gitlab_dst.create_issue(project_dst.id, 
            issue.title,
            description: issue.description,
            assignee_id: assignee_id,
            milestone_id: milestone_id,
            labels: issue.labels.join(",")
            )

          if issue.state == "closed"
            gitlab_dst.edit_issue(project_dst.id, new_issue.id, state_event: "close")
          end
          migrate_issue_notes(gitlab_src, gitlab_dst, project_src, project_dst, issue, new_issue, usermap)
        end

        Helper.log.info("Issues created")
      end

      def self.migrate_issue_notes(gitlab_src, gitlab_dst, project_src, project_dst, issue_src, issue_dst, usermap)
        Helper.log.info("Migrating issue notes for issue #{issue_src.id}")
        read_issue_notes(gitlab_src, project_src, issue_src).each do |note|
          body = "_Original comment by #{note.author.username} on #{Time.parse(note.created_at).strftime("%d %b %Y, %H:%M")}_\n\n---\n\n#{note.body}"
          gitlab_dst.create_issue_note(project_dst.id, issue_dst.id, body)
        end
        Helper.log.info("Migrated issue notes for issue #{issue_src.id}")
      end

      #
      # Read Paginated Resources completely
      #
      def self.read_groups(client)
        groups = []
        page = 1
        page_size = 20
        while true
          groups_page = client.groups(per_page: page_size, page: page)
          page += 1 
          groups += groups_page
          if groups_page.count < page_size
            break
          end
        end
        groups
      end

      def self.read_users(client)
        users = []
        page = 1
        page_size = 20
        while true
          users_page = client.users(per_page: page_size, page: page)
          page += 1 
          users += users_page
          if users_page.count < page_size
            break
          end
        end
        users
      end

      def self.read_milestones(client, project) 
        milestones = []
        page = 1
        page_size = 20
        while true
          milestones_page = client.milestones(project.id, per_page: page_size, page: page)
          page += 1
          milestones += milestones_page
          if milestones_page.count < page_size
            break
          end
        end
        milestones.sort { |a, b| a.id <=> b.id }
      end

      def self.read_issues(client, project) 
        issues = []
        page = 1
        page_size = 20
        while true
          issues_page = client.issues(project.id, per_page: page_size, page: page)
          page += 1
          issues += issues_page
          if issues_page.count < page_size
            break
          end
        end
        issues.sort { |a, b| a.id <=> b.id }
      end

      def self.read_issue_notes(client, project, issue)
        notes = []
        page = 1
        page_size = 20
        while true
          notes_page = client.issue_notes(project.id, issue.id, per_page: page_size, page: page)
          page += 1
          notes += notes_page
          if notes_page.count < page_size
            break
          end
        end
        notes.sort { |a, b| a.id <=> b.id }
      end

      #####################################################
      # @!group Documentation
      #####################################################

      def self.description
        "Creates a project in the target gitlab instance based on the input project"
      end

      def self.details
        "The input project is expected to come from the source gitlab instance. A new project will be created in the target gitlab instance based on the given project"
      end

      def self.available_options
        # Define all options your action supports.
        [
          FastlaneCore::ConfigItem.new(key: :endpoint_src,
                                       env_name: "FL_GITLAB_CREATE_PROJECT_ENDPOINT_SRC",
                                       description: "Source Endpoint for GitlabeCreateProjectAction",
                                       is_string: true,
                                       verify_block: proc do |value|
                                          raise "No Source Endpoint for GitlabeCreateProjectAction given, pass using `endpoint_src: 'url'`".red unless (value and not value.empty?)
                                       end),
          FastlaneCore::ConfigItem.new(key: :api_token_src,
                                       env_name: "FL_GITLAB_CREATE_PROJECT_API_TOKEN_SRC",
                                       description: "Source API-Token for GitlabeCreateProjectAction",
                                       is_string: true,
                                       verify_block: proc do |value|
                                          raise "No Source API-Token for GitlabeCreateProjectAction given, pass using `api_token_src: 'token'`".red unless (value and not value.empty?)
                                       end),
          FastlaneCore::ConfigItem.new(key: :endpoint_dst,
                                       env_name: "FL_GITLAB_CREATE_PROJECT_ENDPOINT_DST",
                                       description: "Destination Endpoint for GitlabeCreateProjectAction",
                                       is_string: true,
                                       verify_block: proc do |value|
                                          raise "No Destination Endpoint for GitlabeCreateProjectAction given, pass using `endpoint_dst: 'url'`".red unless (value and not value.empty?)
                                       end),
          FastlaneCore::ConfigItem.new(key: :api_token_dst,
                                       env_name: "FL_GITLAB_CREATE_PROJECT_API_TOKEN_DST",
                                       description: "Destination API-Token for GitlabeCreateProjectAction",
                                       is_string: true,
                                       verify_block: proc do |value|
                                          raise "No Destination API-Token for GitlabeCreateProjectAction given, pass using `api_token_dst: 'token'`".red unless (value and not value.empty?)
                                       end),
          FastlaneCore::ConfigItem.new(key: :project,
                                       env_name: "FL_GITLAB_CREATE_PROJECT_PROJECT",
                                       description: "The project that should be created in the target gitlab instance, is expected to be from the source gitlab instance",
                                       is_string: false)
        ]
      end

      def self.output
        # Define the shared values you are going to provide
        []
      end

      def self.return_value
        # If you method provides a return value, you can describe here what it does
        "Returns the project that was created in the target gitlab instance"
      end

      def self.authors
        # So no one will ever forget your contribution to fastlane :) You are awesome btw!
        ["cs_mexx"]
      end

      def self.is_supported?(platform)
        true
      end
    end
  end
end