module Fastlane
  module Actions
    module SharedValues
    end

    require 'gitlab'
    require 'pp'

    class GitlabCreateProjectAction < Action
      def self.run(params)
        source = Gitlab.client(endpoint: params[:endpoint_src], private_token: params[:api_token_src])
        destination = Gitlab.client(endpoint: params[:endpoint_dst], private_token: params[:api_token_dst])
        original_project = params[:project]
        if original_project.owner
          owner_id = original_project.owner.id
        else
          owner_id = -1
        end

        project_dst = params[:project_dst]
        UI.message ("Creating Project: #{project_dst}")

        # Check if the Group and Namespace for the Project exist already
        #group = ensure_group(source, destination, original_project.namespace, user_mapping, user_mapping[owner_id])

        # Load project
        destination_project = destination.project(project_dst)
        UI.message ("See #{destination_project.id}")

        # Sanity check
        raise "Project not private #{destination_project.visibility}" unless destination_project.visibility == 'private'

        # Estimate User-Mapping
        # users = destination.group_members()
        destination_group_name = project_dst.split('/').first
        destination_groups = destination.group_search(destination_group_name)

        raise "Group not found" unless destination_groups.count == 1

        destination_group = destination_groups.first
        destination_users = destination.group_members(destination_group.id).auto_paginate
        original_users = source.users.auto_paginate

        user_mapping = map_users(original_users, destination_users)

        UI.message("Project to be used ID: #{destination_project.id} -  #{destination_project}")

        # Create Deploy Keys
        # migrate_deploy_keys(source, destination, original_project, new_project)

        # Create Labels
        migrate_labels(source, destination, original_project, destination_project)

        # Create Milestones
        milestone_mapping = migrate_milestones(source, destination, original_project, destination_project)

        # Create Issues
        migrate_issues(source, destination, original_project, destination_project, user_mapping, milestone_mapping)

        # Create Snippets
        #migrate_snippets(source, destination, original_project, new_project, destination_project)

        destination_project
      end

      # Given a group (with path-name) from the original project, 
      # checks if a group with the same path-name exists in the destination gitlab.
      # If necessary, a group with that path-name is created
      # The group (in the destination gitlab) is returned
      def self.ensure_group(gitlab_src, gitlab_dst, namespace, user_mapping, dst_owner_id)
        UI.message("Searching for group with name '#{namespace.name}' and path: '#{namespace.path}'")
        group = gitlab_dst.groups.auto_paginate.select { |g| g.path == namespace.path}.first
        if group
          UI.message("Existing group '#{group.name}' found")
        else
          group = gitlab_dst.namespaces.auto_paginate.select { |g| g.id == dst_owner_id and g.kind == 'user'}.first
          if group
            UI.message("Existing namespace id '#{group.id}' path '#{group.path}' kind '#{group.kind}'")
          else
            UI.message("Group '#{namespace.name}' does not yet exist, will be created now")
            group = gitlab_dst.create_group(namespace.name, namespace.path)
            # Populate group with users
            # Keep in mind: User-Mapping is estimated and not guaranteed. Users have to exist in the new gitlab 
            # before migrating projects and their name or username has to match their name/username in the old gitlab
            original_group = gitlab_src.group(namespace.id)
            gitlab_src.group_members(original_group.id).auto_paginate do |user|
              gitlab_dst.add_group_member(group.id, user_mapping[user.id], user.access_level) if user_mapping[user.id]
            end
          end
        end
        group
      end

      # Reads all users from the source gitlab and sees if there is an existing user (with the same name)
      # in the new gitlab. If so, an entrie to map the old id to the new id is inserted into the user map
      def self.map_users(original_users, destination_users)
        users_src = original_users
        users_dst = destination_users

        user_map = {}
        users_src.each do |user|
          users = users_dst.select { |u| u.username == user.username or u.name == user.name}
          if users.count == 1
            # Only map users that are unambiguously the same. If there are several matches, dont match them
            UI.message("Mapping user #{user.username} to #{users.first.username}: #{user.id}=#{users.first.id}")
            user_map[user.id] = users.first.id
          end
        end
        UI.message("User Mapping determined: #{user_map}")
        user_map
      end

      # Reads all labels from the source project and create them in the destination project
      # Labels are later referenced by name, so we dont need to return an ID-Mapping
      def self.migrate_labels(gitlab_src, gitlab_dst, project_src, project_dst)
        UI.message("Creating Labels")
        labels = gitlab_src.labels(project_src.id).auto_paginate.each do |label|
          gitlab_dst.create_label(project_dst.id, label.name, label.color)
        end
        UI.message("Labels created")
      end

      def self.migrate_snippets(gitlab_src, gitlab_dst, project_src, project_dst, user_mapping)
        UI.message("Migrating snippets")
        snipptes = gitlab_src.snippets(project_src.id).auto_paginate.each do |snippet|
          code = gitlab_src.snippet_content(project_src.id, snippet.id)
          UI.message("Snippet: '#{snippet.title}'")
          if snippet.file_name.empty?
            # TODO: make sure 'snippet_file_name' contains only letters, digits, '_', '-', '@' and '.' 
            snippet_file_name = snippet.title.delete(' ') + "." + snippet.id.to_s
          else
            snippet_file_name = snippet.file_name
          end
          UI.message("Snippet filename '#{snippet_file_name}'")
          new_snippet = gitlab_dst.create_snippet(project_dst.id, { 
            title: snippet.title, 
            file_name: snippet_file_name,
            code: code, 
            visibility_level: 10
          })
          migrate_snippet_notes(gitlab_src, gitlab_dst, project_src, project_dst, snippet, new_snippet, user_mapping)
        end
      end

      def self.migrate_snippet_notes(gitlab_src, gitlab_dst, project_src, project_dst, snippet_src, snippet_dst, usermap)
        UI.message("Migrating snippet notes for snippet #{snippet_src.id}")
        gitlab_src.snippet_notes(project_src.id, snippet_src.id).auto_paginate.sort { |n1, n2| n1.id <=> n2.id }.each do |note |
          body = "_Original comment by #{note.author.username} on #{Time.parse(note.created_at).strftime("%d %b %Y, %H:%M")}_\n\n---\n\n#{note.body}"
          gitlab_dst.create_snippet_note(project_dst.id, snippet_dst.id, body)
        end
        UI.message("Migrated snippet notes for snippet #{snippet_src.id}")
      end

      # Reads all deploy-keys from the source project and create them in the destination project
      def self.migrate_deploy_keys(gitlab_src, gitlab_dst, project_src, project_dst)
        UI.message("Creating Deploy-Keys")
        labels = gitlab_src.deploy_keys(project_src.id).auto_paginate.each do |key|
          gitlab_dst.create_deploy_key(project_dst.id, key.title, key.key)
        end
        UI.message("Deploy-Keys created")
      end

      # Reads all milestones from the source project and create them in the destination project
      # Milestones are later referenced by ID, so we need to return a mapping from milestone-id in the old project to milestone-id in the new project
      def self.migrate_milestones(gitlab_src, gitlab_dst, project_src, project_dst) 
        UI.message("Migrating Milestones")
        milestone_map = {}
        gitlab_src.milestones(project_src.id).auto_paginate.sort { |m1, m2| m1.id <=> m2.id }.each do |milestone|
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
        UI.message("Milestones migrated, milestone map generated: #{milestone_map}")
        milestone_map
      end

      def self.migrate_issues(gitlab_src, gitlab_dst, project_src, project_dst, usermap, milestonemap)
        UI.message("Creating Issues")

        UI.message("Usermap: #{usermap}")
        UI.message("Milestonemap: #{milestonemap}")

        gitlab_src.issues(project_src.id).auto_paginate.sort { |i1, i2| i1.id <=> i2.id }.each do |issue|
          assignee_id = usermap[issue.assignee.id] if issue.assignee
          milestone_id = milestonemap[issue.milestone.id] if issue.milestone
          new_issue = gitlab_dst.create_issue(project_dst.id, 
            issue.title,
            description: issue.description,
            assignee_id: assignee_id,
            milestone_id: milestone_id,
            labels: issue.labels.join(","),
            due_date: issue.due_date,
            created_at: issue.created_at,
            updated_at: issue.updated_at
            )

          if issue.state == "closed"
            gitlab_dst.edit_issue(project_dst.id, new_issue.iid, state_event: "close")
          end
          migrate_issue_notes(gitlab_src, gitlab_dst, project_src, project_dst, issue, new_issue, usermap)
        end

        UI.message("Issues created")
      end

      def self.migrate_issue_notes(gitlab_src, gitlab_dst, project_src, project_dst, issue_src, issue_dst, usermap)
        UI.message("Migrating issue notes for issue #{issue_src.iid}")
        gitlab_src.issue_notes(project_src.id, issue_src.iid).auto_paginate.sort { |n1, n2| n1.iid <=> n2.iid }.each  do |note|
          body = "_Original comment by #{note.author.username} on #{Time.parse(note.created_at).strftime("%d %b %Y, %H:%M")}_\n\n---\n\n#{note.body}"
          gitlab_dst.create_issue_note(project_dst.id, issue_dst.iid, body)
        end
        UI.message("Migrated issue notes for issue #{issue_src.iid}")
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
                                       env_name: "FL_GITLAB_ENDPOINT_SRC",
                                       description: "Source Endpoint for GitlabeCreateProjectAction",
                                       is_string: true,
                                       verify_block: proc do |value|
                                          raise "No Source Endpoint for GitlabeCreateProjectAction given, pass using `endpoint_src: 'url'`".red unless (value and not value.empty?)
                                       end),
          FastlaneCore::ConfigItem.new(key: :api_token_src,
                                       env_name: "FL_GITLAB_TOKEN_SRC",
                                       description: "Source API-Token for GitlabeCreateProjectAction",
                                       is_string: true,
                                       verify_block: proc do |value|
                                          raise "No Source API-Token for GitlabeCreateProjectAction given, pass using `api_token_src: 'token'`".red unless (value and not value.empty?)
                                       end),
          FastlaneCore::ConfigItem.new(key: :endpoint_dst,
                                       env_name: "FL_GITLAB_ENDPOINT_DST",
                                       description: "Destination Endpoint for GitlabeCreateProjectAction",
                                       is_string: true,
                                       verify_block: proc do |value|
                                          raise "No Destination Endpoint for GitlabeCreateProjectAction given, pass using `endpoint_dst: 'url'`".red unless (value and not value.empty?)
                                       end),
          FastlaneCore::ConfigItem.new(key: :api_token_dst,
                                       env_name: "FL_GITLAB_TOKEN_DST",
                                       description: "Destination API-Token for GitlabeCreateProjectAction",
                                       is_string: true,
                                       verify_block: proc do |value|
                                          raise "No Destination API-Token for GitlabeCreateProjectAction given, pass using `api_token_dst: 'token'`".red unless (value and not value.empty?)
                                       end),
          FastlaneCore::ConfigItem.new(key: :project,
                                       env_name: "FL_GITLAB_CREATE_PROJECT_PROJECT",
                                       description: "The project that should be created in the target gitlab instance, is expected to be from the source gitlab instance",
                                       is_string: false),
          FastlaneCore::ConfigItem.new(key: :project_dst,
                                       env_name: "FL_GITLAB_CREATE_PROJECT_PROJECT_DST",
                                       description: "Project destination",
                                       is_string: true)
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
