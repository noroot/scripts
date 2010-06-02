#
# Redmine task for importing issues from JIRA (http://www.atlassian.com/software/jira/)
#
require 'active_record'
require 'iconv'
require 'pp'
require 'enumerator'

namespace :redmine do
  desc 'Jira migration script'
  task :import_from_jira => :environment do
    
    module JiraMigrate
      priorities = IssuePriority.all
      DEFAULT_PRIORITY = priorities[0]
      

      #
      # setup statuses
      #
      DEFAULT_STATUS = IssueStatus.default
      assigned_status = IssueStatus.find_by_name("New")
      resolved_status = IssueStatus.find_by_name("Resolved")
      feedback_status = IssueStatus.find_by_name("Feedback")
      closed_status = IssueStatus.find :first, :conditions => { :is_closed => true }
      
      STATUS_MAPPING = {
        'open' => DEFAULT_STATUS,
        'reopened' => feedback_status,
        'resolved' => resolved_status,
        'in progress' => assigned_status,
        'closed' => closed_status
      }
      
      
      # 
      # setup tracker types
      # 
      TRACKER_BUG = Tracker.find_by_name("Bug")
      TRACKER_FEATURE = Tracker.find_by_name("Feature")
      TRACKER_TASK = Tracker.find_by_name("Support")
      
      DEFAULT_TRACKER = TRACKER_BUG
      TRACKER_MAPPING = {
        'bug' => TRACKER_BUG,
        'enhancement' => TRACKER_FEATURE,
        'task' => TRACKER_TASK,
        'new feature' =>TRACKER_FEATURE
      }
      DEFAULT_TRACKER = TRACKER_BUG

      PRIORITY_MAPPING = {
        'trivial' => priorities[0],
        'minor' => priorities[1],
        'major' => priorities[2],
        'critical' => priorities[3],
        'blocker' => priorities[4]
      }
				
      roles = Role.find(:all, :conditions => {:builtin => 0}, :order => 'position ASC')
      manager_role = roles[0]
      developer_role = roles[1]
      DEFAULT_ROLE = roles.last
      ROLE_MAPPING = {
        'admin' => manager_role,
        'developer' => developer_role
      }
      
      class JiraIssue
        TITLE_RX = /^\[([^\]]+)-(\d+)\]\s*(.*)$/o
        
        attr_reader :node
        
        def initialize node
          @node = node
        end

        def [] name
          node.elements[name.to_s]
        end
        
        def method_missing name, *args
          if name.to_s =~ /^[a-z]+$/ and args.empty?
            n = self[name]
            return n ? n.text : nil
          end
          super
        end
        
        def project_id
          method_missing(:title)[TITLE_RX, 1]
        end
        
        def issue_id
          method_missing(:title)[TITLE_RX, 2].to_i
        end
        
        def title
          method_missing(:title)[TITLE_RX, 3]
        end
        
        def type
          method_missing :type
        end
        
        def inspect
          "#<#{self.class} project_id=%p issue_id=%d title=%p>" % [project_id, issue_id, title]
        end
      end
      
      def self.find_or_create_user(username, fullname, project=nil)
        if username == '-1'
          return nil
        end
        
        u = User.find_by_login(username)
        if !u
          # Create a new user if not found
          mail = username[0,limit_for(User, 'mail')]
          mail = "#{mail}@domain.com" unless mail.include?("@")
          firstname, lastname = fullname.split ' ', 2
          u = User.new :firstname => firstname[0,limit_for(User, 'firstname')],
          :lastname => lastname[0,limit_for(User, 'lastname')],
          :mail => mail.gsub(/[^-@a-z0-9\.]/i, '-')
          u.login = username[0,limit_for(User, 'login')].gsub(/[^a-z0-9_\-@\.]/i, '-')
          u.password = 'jira'
          # finally, a default user is used if the new user is not valid
          u = User.find(:first) unless u.save
        end
        # Make sure he is a member of the project
        if project && !u.member_of?(project)
          roles = [DEFAULT_ROLE]
          roles = [ROLE_MAPPING['admin']] if u.admin
          Member.create(:user => u, :project => project, :roles => roles)
          u.reload
        end
        u
      end
      
      def self.clean_html html
        text = html.
          # normalize whitespace
          gsub(/\s+/m, ' ').
          # add in line breaks
          gsub(/<br.*?>\s*/i, "\n").
          # remove all tags
          gsub(/<.*?>/, ' ').
          # handle entities
          gsub(/&amp;/, '&').gsub(/&lt;/, '<').gsub(/&gt;/, '>').gsub(/&nbsp;/, ' ').gsub(/&quot;/, '"').
          # clean up
          squeeze(' ').gsub(/ *$/, '').strip
        #				puts "cleaned html from #{html.inspect} to #{text.inspect}"
        text
      end
      
      def self.migrate
        migrated_projects = 0
        migrated_components = 0
        migrated_issues = 0
        
        open issue_xml do |file|
          doc = REXML::Document.new file
          item_nodes = doc.elements.to_enum :each, '/rss/channel/item'
          issues = item_nodes.map { |item_node| JiraIssue.new item_node }
          issues_by_project = issues.group_by { |issue| issue.project_id }
          #					print @issues
          
          # Projects
          print "Migrating projects"
          # puts 
          project_from_project_id = {}
          # puts issues.inspect
          # issues.each { |issue | puts "#{issue.issue_id} #{issue.title}" }
          # exit
              
          puts
          issues_by_project.keys.sort.each do |project_id|
            # print '.' #
            STDOUT.flush
            identifier = project_id.downcase #+ '-' + @target_project.id.to_s
            puts "import #{project_id}"
            project = Project.find_by_identifier(identifier)
            if !project
              # create the target project
              project = Project.new :name => identifier.humanize,:description => "Imported project from jira (#{identifier.upcase})." #identifier.humanize
              project.identifier = identifier
              puts "Unable to create a sub project with identifier '#{identifier}'!" unless project.save
              project.move_to_child_of(@target_project.id)
              # enable issues for the created project
              project.enabled_module_names = ['issue_tracking']
            end
            project.trackers << TRACKER_BUG
            project.trackers << TRACKER_FEATURE
            project.trackers << TRACKER_TASK
            project_from_project_id[project_id] = project
            migrated_projects += 1
          end
          puts
          
          # Components
          print "Migrating components"
          component_from_project_and_name = {}
          issues_by_project.each do |project_id, project_issues|
            components = project_issues.map { |issue| issue.component }.flatten.uniq.compact
            components.each do |component|
              # print '.'
              STDOUT.flush
              c = IssueCategory.new :project => project_from_project_id[project_id],:name => encode(component[0, limit_for(IssueCategory, 'name')])
              next unless c.save
              component_from_project_and_name[[project_id, component]] = c
              migrated_components += 1
            end
          end
          puts
          
          # Issues
          puts "Migrating issues "
          issues_by_project.each do |project_id, project_issues|
            project = project_from_project_id[project_id]
            project_issues.each do |issue|
              
              if issue!= nil 
                print '*'
                STDOUT.flush
                
                i = Issue.new :project => project,
                :subject => encode(issue.title[0, limit_for(Issue, 'subject')]),
                :description => clean_html(issue.description || issue.title), #convert_wiki_text(encode(ticket.description)),
                :priority => PRIORITY_MAPPING[issue.priority.to_s.downcase] || DEFAULT_PRIORITY,
                :created_on => Time.parse(issue.created),
                :updated_on => Time.parse(issue.updated)
                
                
                i.status = STATUS_MAPPING[issue.status.to_s.downcase] || DEFAULT_STATUS
                i.tracker = TRACKER_MAPPING[issue.type.to_s.downcase] || DEFAULT_TRACKER
                
                if reporter = issue['reporter']
                  i.author = find_or_create_user reporter.attributes['username'], reporter.text
                end

                i.category = component_from_project_and_name[[project_id, issue.component]] if issue.component
                i.save!
                
                # Assignee
                if assignee = issue['assignee']
                  i.assigned_to = find_or_create_user assignee.attributes['username'], assignee.text, project
                  i.save
                end
                
                # force the issue update date back. it gets overwritten on save time.
                Issue.connection.execute <<-end
								update issues set updated_on = '#{Time.parse(issue.updated).to_s :db}' where id = #{i.id}
							end
                
                migrated_issues += 1
                
                # Comments
                if comments = issue.node.elements['comments']
                last_comment = '1'
                  comments.elements.to_a('.//comment').each do |comment|
                    author, created = comment.attributes['author'], comment.attributes['created']
                    comment_text = clean_html comment.text
                    n = Journal.new :notes => comment_text,
                    :created_on => DateTime.parse(created)
                    n.user = find_or_create_user(author, "#{author.capitalize} -")
                    n.journalized = i
                    n.save unless n.details.empty? && n.notes.blank?
                  end
                else
                  print "."

                end
              end
            end
          end
          puts
          
          puts
          puts "Projects:        #{migrated_projects}/#{issues_by_project.keys.length}"
#          puts "Components:      #{migrated_components}/#{migrated_components}" # hmmm
          puts "Issues:          #{migrated_issues}/#{issues.length}"
        end
      end
      
      def self.limit_for(klass, attribute)
        klass.columns_hash[attribute.to_s].limit
      end
      
      def self.encoding(charset)
        @ic = Iconv.new('UTF-8', charset)
      rescue Iconv::InvalidEncoding
        puts "Invalid encoding!"
        return false
      end
      
      def self.set_issue_xml file
        @@issue_xml = file
      end
      
      mattr_reader :issue_xml
      
      def self.target_project_identifier(identifier)
        project = Project.find_by_identifier(identifier)
        if !project
          project = Project.new :name => 'Jira Import',
          :description => 'All issues imported from jira.'
          project.identifier = identifier
          puts "Unable to create a project with identifier '#{identifier}'!" unless project.save
          # enable issues for the created project
          project.enabled_module_names = ['issue_tracking']
        end        
        #project.trackers << TRACKER_BUG
        #project.trackers << TRACKER_FEATURE          
        @target_project = project.new_record? ? nil : project
      end
      
      private
      def self.encode(text)
        @ic.iconv text
      rescue
        text
      end
    end
		
    puts
  
    def prompt(text, options = {}, &block)
      default = options[:default] || ''
      while true
        print "#{text} [#{default}]: "
        value = STDIN.gets.chomp!
        value = default if value.blank?
        break if yield value
      end
    end
    

    puts "-------------------"
    puts "JIRA migration tool"
    puts "-------------------"

    prompt('Jira issue xml file', :default => '/usr/share/redmine/lib/tasks/SearchRequest.xml') {|file| JiraMigrate.set_issue_xml file}
    JiraMigrate.target_project_identifier('jira')
    puts
    JiraMigrate.migrate
  end
end
