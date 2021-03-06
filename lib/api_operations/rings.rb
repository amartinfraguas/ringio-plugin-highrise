module ApiOperations

  module Rings


    HR_RING_NOTE_MARK = "Phone Call"


    def self.synchronize_account(account, new_user_maps)

      ApiOperations::Common.log(:debug,nil,"Started the synchronization of the rings of the account with id = " + account.id.to_s)

      # run a synchronization just for each new user map
      new_user_maps.each do |um|
        self.synchronize_account_process(account,um)
      end

      # run a normal complete synchronization
      self.synchronize_account_process(account,nil) unless account.not_synchronized_yet

      self.update_timestamps account

      ApiOperations::Common.log(:debug,nil,"Finished the synchronization of the rings of the account with id = " + account.id.to_s)
    end


    private


      def self.synchronize_account_process(account, new_user_map)
        # if there is a new user map
        if new_user_map
          ApiOperations::Common.log(:debug,nil,"Started ring synchronization for the new user map with id = " + new_user_map.id.to_s + " of the account with id = " + account.id.to_s)

          begin
            # get the feed of changed rings per contact of this new user map from Ringio,
            # we will not check for deleted rings, because they cannot be deleted
            account_rg_feed = account.all_rg_rings_feed
            contact_rg_feeds = self.fetch_contact_rg_feeds(new_user_map,account_rg_feed,account)
          rescue Exception => e
            ApiOperations::Common.log(:error,e,"\nProblem fetching the changed rings for the new user map with id = " + new_user_map.id.to_s + " of the account with id = " + account.id.to_s)
          end
        else
          begin
            # get the feed of changed rings per contact of this Ringio account from Ringio,
            # we will not check for deleted rings, because they cannot be deleted
            account_rg_feed = account.rg_rings_feed
            ApiOperations::Common.log(:debug,nil,"Getting the changed rings of the account with id = " + account.id.to_s)
            contact_rg_feeds = self.fetch_contact_rg_feeds(nil,account_rg_feed,account)
          rescue Exception => e
            ApiOperations::Common.log(:error,e,"\nProblem fetching the changed rings of the account with id = " + account.id.to_s)
          end
        end
        
        self.synchronize_contacts contact_rg_feeds
        
        if new_user_map
          ApiOperations::Common.log(:debug,nil,"Finished ring synchronization for the new user map with id = " + new_user_map.id.to_s + " of the account with id = " + account.id.to_s)
        end
      end


      def self.update_timestamps(account)
        begin
          # update timestamps: we must set the timestamp AFTER the changes we made in the synchronization, or
          # we would update those changes again and again in every synchronization (and, to keep it simple, we ignore
          # the changes that other agents may have caused for this account just when we were synchronizing)
          # TODO: ignore only our changes but not the changes made by other agents
          
          rg_timestamp = account.rg_rings_feed.timestamp
          if rg_timestamp && rg_timestamp > account.rg_rings_last_timestamp
            account.rg_rings_last_timestamp = rg_timestamp
          else
            ApiOperations::Common.log(:error,nil,"\nProblem with the Ringio rings timestamp of the account with id = " + account.id.to_s)
          end
          
          hr_timestamp = ApiOperations::Common.hr_current_timestamp account
          if hr_timestamp && hr_timestamp > account.hr_ring_notes_last_synchronized_at
            account.hr_ring_notes_last_synchronized_at = hr_timestamp
          else
            ApiOperations::Common.log(:error,nil,"\nProblem with the Highrise ring notes timestamp of the account with id = " + account.id.to_s)
          end

          account.save!
        rescue Exception => e
          ApiOperations::Common.log(:error,e,"\nProblem updating the ring synchronization timestamps of the account with id = " + account.id.to_s)
        end      
      end

      
      def self.synchronize_contacts(contact_rg_feeds)
        begin
          # synchronize each contact whose rings have changed
          contact_rg_feeds.each do |contact_feed|
            begin
              ApiOperations::Common.set_hr_base(contact_feed[0].user_map)
              self.synchronize_contact(contact_feed)
              ApiOperations::Common.empty_hr_base
            rescue Exception => e
              ApiOperations::Common.log(:error,e,"\nProblem synchronizing the rings created for the contact map with id = " + contact_feed[0].id.to_s)
            end
          end
        rescue Exception => e
          ApiOperations::Common.log(:error,e,"\nProblem synchronizing the rings")
        end
      end
      
      
      # returns an array with each element containing information for each contact map:
      # [0] => contact map
      # [1] => updated Ringio rings for this contact map
      # we will choose the author of the ring event note in Highrise as the owner of the contact 
      def self.fetch_contact_rg_feeds(new_user_map, account_rg_feed, account)
        account_rg_feed.updated.inject([]) do |contact_feeds,rg_ring_id|
          rg_ring = RingioAPI::Ring.find rg_ring_id

          if rg_ring.attributes['from_type'].present? && rg_ring.from_type == 'contact'
            self.process_rg_ring_user_map(new_user_map,rg_ring.from_id,contact_feeds,rg_ring,account)
          elsif rg_ring.attributes['to_type'].present? && rg_ring.to_type == 'contact'
            self.process_rg_ring_user_map(new_user_map,rg_ring.to_id,contact_feeds,rg_ring,account)
          end

          contact_feeds
        end
      end


      def self.process_rg_ring_user_map(new_user_map, rg_contact_id, contact_feeds, rg_ring, account)
        # synchronize only notes of contacts already mapped for this account
        if new_user_map
          if (cm = ContactMap.find_by_user_map_id_and_rg_contact_id(new_user_map.id,rg_contact_id))
            self.process_rg_ring(cm,contact_feeds,rg_ring)
          end
        else
          if (cm = ContactMap.find_by_rg_contact_id(rg_contact_id)) && (cm.user_map.account == account)
            self.process_rg_ring(cm,contact_feeds,rg_ring)
          end
        end
      end

      
      def self.process_rg_ring(contact_map, contact_feeds, rg_ring)
        if (cf_index = contact_feeds.index{|cf| cf[0] == contact_map})
          contact_feeds[cf_index][1] << rg_ring
        else
          contact_feeds << [contact_map,[rg_ring]]
        end
      end


      def self.synchronize_contact(contact_rg_feed)
        # we will only check for changed rings in Ringio, as they should not be changed in Highrise
        contact_map = contact_rg_feed[0]
        ApiOperations::Common.log(:debug,nil,"Started applying ring changes for the contact map with id = " + contact_map.id.to_s)
        rg_updated_rings = contact_rg_feed[1]
        
        # we will only check for updated rings, as they cannot be deleted
        rg_updated_rings.each do |rg_ring|
          begin
            ApiOperations::Common.log(:debug,nil,"Started applying update from Ringio to Highrise of the ring with Ringio id = " + rg_ring.id.to_s)
            
            # if the ring was already mapped to Highrise, update it there
            if (rm = RingMap.find_by_rg_ring_id(rg_ring.id))
              hr_ring_note = rm.hr_resource_ring_note
              self.rg_ring_to_hr_ring_note(contact_map,rg_ring,hr_ring_note)
            else
            # if the note is new, create it in Highrise and map it
              hr_ring_note = Highrise::Note.new
              self.rg_ring_to_hr_ring_note(contact_map,rg_ring,hr_ring_note)
            end
            
            # if the Highrise note is saved properly and it didn't exist before, create a new ring map
            new_hr_ring_note = hr_ring_note.new?
            unless new_hr_ring_note
              hr_ring_note = self.remove_subject_name(hr_ring_note)
            end
            if hr_ring_note.save! && new_hr_ring_note
              new_rm = RingMap.new(:contact_map_id => contact_map.id, :rg_ring_id => rg_ring.id, :hr_ring_note_id => hr_ring_note.id)
              new_rm.save!
            end
            
            ApiOperations::Common.log(:debug,nil,"Finished applying update from Ringio to Highrise of the ring with Ringio id = " + rg_ring.id.to_s)
          rescue Exception => e
            ApiOperations::Common.log(:error,e,"Problem applying update from Ringio to Highrise of the ring with Ringio id = " + rg_ring.id.to_s)
          end
        end
        
        ApiOperations::Common.log(:debug,nil,"Finished applying ring changes for the contact map with id = " + contact_map.id.to_s)
      end


      def self.remove_subject_name(hr_ring_note)
        # TODO: remove this method or find a better way to do it (answer pending in the 37signals mailing list) 
        Highrise::Note.new(
          :author_id => hr_ring_note.author_id,
          :body => hr_ring_note.body,
          :collection_id => hr_ring_note.collection_id,
          :collection_type => hr_ring_note.collection_type,
          :created_at => hr_ring_note.created_at,
          :group_id => hr_ring_note.group_id,
          :id => hr_ring_note.id,
          :owner_id => hr_ring_note.owner_id,
          :subject_id => hr_ring_note.subject_id,
          :subject_type => hr_ring_note.subject_type,
          :updated_at => hr_ring_note.updated_at,
          :visible_to => hr_ring_note.visible_to
        )
      end


      def self.rg_ring_to_hr_ring_note(contact_map, rg_ring, hr_ring_note)
        # Highrise assumes that the author of the ring note is the currently authenticated user, we don't have to specify the author_id
        hr_ring_note.subject_id = contact_map.hr_party_id
        hr_ring_note.subject_type = 'Party'
        # it is not necessary to specify if it is a Person or a Company (they can't have id collision),
        # and Highrise does not offer a way to specify it
        
        extract_name = lambda do |type,id|
          case type
            when 'user'
              begin
                RingioAPI::User.find(id).name
              rescue ActiveResource::ResourceNotFound
                'deleted'
              end
            when 'contact' then RingioAPI::Contact.find(id).name
            else
              raise 'Unknown Ring From type'
          end
        end
        
        from_name = extract_name.call(rg_ring.from_type,rg_ring.from_id) if rg_ring.attributes['from_type'].present?
        
        to_name = extract_name.call(rg_ring.to_type,rg_ring.to_id) if rg_ring.attributes['to_type'].present?

        hr_ring_note.body = HR_RING_NOTE_MARK + "\n" +
                            (rg_ring.attributes['from_type'].present? ? ("From: " + rg_ring.from_type + " " + from_name + " " + rg_ring.callerid + "\n") : '') +
                            (rg_ring.attributes['to_type'].present? ? ("To: " + rg_ring.to_type + " " + to_name + " " + rg_ring.called_number + "\n") : '') +
                            "Start Time: " + rg_ring.start_time + "\n" +
                            "Duration:  " + rg_ring.duration.to_s + "\n" +
                            "Outcome:  " + rg_ring.outcome + "\n" +
                            (rg_ring.attributes['voicemail'].present? ? ("Voicemail:  " + rg_ring.voicemail + "\n") : '') +
                            "Kind:  " + rg_ring.kind + "\n" +
                            (rg_ring.attributes['department'].present? ? ("Department:  " + rg_ring.department + "\n") : '')
                            
        # handle visibility: make it the same as the visibility of the contact
        #   - if the contact is shared in Ringio (group Client), set Highrise visible_to to Everyone
        #   - otherwise, restrict the visibility in Highrise to the owner of the contact
        if contact_map.rg_resource_contact.groups.include?(ApiOperations::Contacts::RG_CLIENT_GROUP)
          hr_ring_note.visible_to = 'Everyone'
        else
          hr_ring_note.visible_to = 'Owner'
          hr_ring_note.owner_id = contact_map.user_map.hr_user_id 
        end
      end

  end

end