namespace :cartodb do
  namespace :db do
    desc "Set DB Permissions"
    task :set_permissions => :environment do
      User.all.each do |user|
        next if !user.respond_to?('database_name') || user.database_name.blank?

        # reset perms
        user.set_database_permissions
        
        # rebuild public access perms from redis
        user.tables.all.each do |table|
          
          # reset public
          if table.public?
            user.in_database(:as => :superuser).run("GRANT SELECT ON #{table.name} TO #{CartoDB::PUBLIC_DB_USER};")
          end
          
          # reset triggers
          table.add_python
          table.set_trigger_update_updated_at
          table.set_trigger_cache_timestamp
          table.set_trigger_check_quota
        end  
      end
    end

    desc "reset Users quota to 100mb or use current setting"
    task :reset_quotas => :environment do
      User.all.each do |user|
        next if !user.respond_to?('database_name') || user.database_name.blank?
        
        user.update(:quota_in_bytes => 104857600) if user.quota_in_bytes.blank?
                
        # rebuild quota trigger
        user.tables.all.each do |table|
        
          # reset quota trigger
          table.add_python
          table.set_trigger_check_quota
        end  
      end
    end

    desc "set users quota to amount in mb"
    task :set_user_quota, [:username, :quota_in_mb] => :environment do |t, args|
      usage = "usage: rake cartodb:db:set_user_quota[username,quota_in_mb]"
      raise usage if args[:username].blank? || args[:quota_in_mb].blank?
      
      user  = User.filter(:username => args[:username]).first
      quota = args[:quota_in_mb].to_i * 1024 * 1024
      user.update(:quota_in_bytes => quota)
              
      # rebuild quota trigger
      user.tables.all.each do |table|
      
        # reset quota trigger
        table.add_python
        table.set_trigger_check_quota
      end  
      
      puts "User: #{user.username} quota updated to: #{args[:quota_in_mb]}MB. #{user.tables_count} tables updated."
    end


    desc "Add the_geom_webmercator column to every table which needs it"
    task :add_the_geom_webmercator => :environment do
      User.all.each do |user|
        tables = Table.filter(:user_id => user.id).all
        next if tables.empty?
        puts "Updating tables from #{user.username}"
        tables.each do |table|
          has_the_geom = false
          user.in_database do |user_database|
            flatten_schema = user_database.schema(table.name.to_sym).flatten
            has_the_geom = true if flatten_schema.include?(:the_geom)
            if flatten_schema.include?(:the_geom) && !flatten_schema.include?(Table::THE_GEOM_WEBMERCATOR.to_sym)
              puts "Updating table #{table.name}"
              geometry_type = if col = user_database["select GeometryType(the_geom) FROM #{table.name} limit 1"].first
                col[:geometrytype]
              end
              geometry_type ||= "POINT"
              user_database.run("SELECT AddGeometryColumn('#{table.name}','#{Table::THE_GEOM_WEBMERCATOR}',#{CartoDB::GOOGLE_SRID},'#{geometry_type}',2)")
              user_database.run("CREATE INDEX #{table.name}_#{Table::THE_GEOM_WEBMERCATOR}_idx ON #{table.name} USING GIST(#{Table::THE_GEOM_WEBMERCATOR})")                      
              user_database.run("VACUUM ANALYZE #{table.name}")
              table.save_changes
            end
          end
          if has_the_geom
            user.in_database(:as => :superuser) do |user_database|
              user_database.run(<<-TRIGGER     
                DROP TRIGGER IF EXISTS update_the_geom_webmercator_trigger ON #{table.name};  
                CREATE OR REPLACE FUNCTION update_the_geom_webmercator() RETURNS trigger AS $update_the_geom_webmercator_trigger$
                  BEGIN
                       NEW.#{Table::THE_GEOM_WEBMERCATOR} := ST_Transform(NEW.the_geom,#{CartoDB::GOOGLE_SRID});
                       RETURN NEW;
                  END;
                $update_the_geom_webmercator_trigger$ LANGUAGE plpgsql VOLATILE COST 100;

                CREATE TRIGGER update_the_geom_webmercator_trigger 
                BEFORE INSERT OR UPDATE OF the_geom ON #{table.name} 
                  FOR EACH ROW EXECUTE PROCEDURE update_the_geom_webmercator();    
  TRIGGER
              )
            end
            user.in_database do |user_database|
              user_database.run("ALTER TABLE #{table.name} DROP CONSTRAINT IF EXISTS enforce_srid_the_geom")
              user_database.run("update #{table.name} set the_geom = ST_Transform(the_geom,#{CartoDB::SRID})")
              user_database.run("ALTER TABLE #{table.name} ADD CONSTRAINT enforce_srid_the_geom CHECK (srid(the_geom) = #{CartoDB::SRID})")
            end
          end
        end
      end
    end
  end
end