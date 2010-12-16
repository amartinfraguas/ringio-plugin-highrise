module ApiOperations

  module Rings

    def self.synchronize_account(account)

      # get the feed of changed rings per contact of this Ringio account from Ringio
      account_rg_feed = account.rg_rings_feed
debugger
      user_rg_feeds = self.fetch_user_rg_feeds(account_rg_feed,account)
      rg_deleted_notes_ids = account_rg_feed.deleted

      # synchronize each user whose notes (note.author_id = user) have changed
      user_rg_feeds.each do |user_feed|
        ApiOperations::Common.set_hr_base(user_feed[0])
        user_feed[1].each do |contact_feed|
          self.synchronize_contact(user_feed[0],contact_feed,rg_deleted_notes_ids)
        end
        ApiOperations::Common.empty_hr_base
      end
      
      # update timestamps: we must set the timestamp AFTER the changes we made in the synchronization, or
      # we would update those changes again and again in every synchronization (and, to keep it simple, we ignore
      # the changes that other agents may have caused for this account just when we were synchronizing)
      # TODO: ignore only our changes but not the changes made by other agents
      account.rg_notes_last_timestamp = account.rg_notes_feed.timestamp
      account.hr_notes_last_synchronized_at = ApiOperations::Common.hr_current_timestamp(account.user_maps.first)
      account.save

    end


    private
      
      # returns an array with each element containing information for each author user map:
      # [0] => author user map
      # [1][i][0] => contact map i
      # [1][i][1] => updated Ringio rings for contact map i and author user map
      def self.fetch_user_rg_feeds(account_rg_feed, account)

        account_rg_feed.updated.inject([]) do |user_feeds,rg_ring_id|
          rg_ring = RingioAPI::Ring.find rg_ring_id
          
          if rg_ring.from_type = 'contact'
            process_rg_rings(rg_ring.from_id,user_feeds,rg_ring)
          elsif rg_ring.to_type = 'contact'
            process_rg_rings(rg_ring.to_id,user_feeds,rg_ring)
          end

          user_feeds
        end
        
      end


      def self.process_rg_rings(rg_contact_id, user_feeds, rg_ring)
debugger
        # synchronize only rings from contacts of users already mapped for this account
        if (um = UserMap.find_by_account_id_and_rg_user_id(account.id,rg_note.author_id))
          # synchronize only notes of contacts already mapped for this account
          if (cm = ContactMap.find_by_rg_contact_id(rg_note.contact_id)) && (cm.user_map.account == account)
            if (uf_index = user_feeds.index{|uf| uf[0] == um})
              if (cf_index = user_feeds[uf_index][1].index{|cf| cf[0] == cm})
                user_feeds[uf_index][1][cf_index][1] << rg_note
              else
                user_feeds[uf_index][1] << [cm,[rg_note]]
              end
            else
              user_feeds << [ um , [[cm,[rg_note]]] ]
            end
          end
        end
      end


      def self.synchronize_contact(user_map, contact_rg_feed, rg_deleted_notes_ids)

        contact_map = contact_rg_feed[0]

        hr_updated_note_recordings = contact_map.hr_updated_note_recordings
        # TODO: get true feeds of deleted notes (currently Highrise does not offer it)
        hr_notes = contact_map.hr_notes
        # get the deleted notes (those that don't appear anymore in the total)
        hr_deleted_notes_ids = contact_map.note_maps.reject{|nm| hr_notes.index{|hr_n| hr_n.id == nm.hr_note_id}}.map{|nm| nm.hr_note_id} 
 
        # give priority to Highrise: discard changes in Ringio to notes that have been changed in Highrise
        self.purge_notes(hr_updated_note_recordings,hr_deleted_notes_ids,contact_rg_feed[1],rg_deleted_notes_ids)
        
        self.apply_changes_rg_to_hr(contact_map,contact_rg_feed[1],rg_deleted_notes_ids)

        self.apply_changes_hr_to_rg(user_map,contact_map,hr_updated_note_recordings,hr_deleted_notes_ids)        

      end


      def self.purge_notes(hr_updated_note_recordings, hr_deleted_notes_ids, rg_updated_notes, rg_deleted_notes_ids)
  
        # delete duplicated changes for Highrise updated notes
        hr_updated_note_recordings.each do |r|
          if (nm = NoteMap.find_by_hr_note_id(r.id))
            self.delete_rg_duplicated_changes(nm.rg_note_id,rg_updated_notes,rg_deleted_notes_ids)
          end
        end
        
        # delete duplicated changes for Highrise deleted notes
        hr_deleted_notes_ids.each do |n_id|
          if (nm = NoteMap.find_by_hr_note_id(n_id))
            self.delete_rg_duplicated_changes(nm.rg_note_id,rg_updated_notes,rg_deleted_notes_ids)
          end
        end

      end


      def self.delete_rg_duplicated_changes(rg_note_id, rg_updated_notes, rg_deleted_notes_ids)
        rg_updated_notes.delete_if{|n| n.id == rg_note_id}
        rg_deleted_notes_ids.delete_if{|n_id| n_id == rg_note_id}      
      end


      def self.apply_changes_hr_to_rg(user_map, contact_map, hr_updated_note_recordings, hr_deleted_notes_ids)

        hr_updated_note_recordings.each do |hr_note|
          rg_note = self.prepare_rg_note(contact_map,hr_note)
          self.hr_note_to_rg_note(user_map,contact_map,hr_note,rg_note)
  
          # if the Ringio note is saved properly and it didn't exist before, create a new note map
          new_rg_note = rg_note.new?
          if rg_note.save! && new_rg_note
            new_nm = NoteMap.new(:contact_map_id => contact_map.id, :rg_note_id => rg_note.id, :hr_note_id => hr_note.id)
            new_nm.save!
          end
        end
        
        hr_deleted_notes_ids.each do |n_id|
          # if the note was already mapped to Ringio, delete it there
          if (nm = NoteMap.find_by_hr_note_id(n_id))
            nm.rg_resource_note.destroy
            nm.destroy
          end
          # otherwise, don't do anything, because that Highrise party has not been created yet in Ringio
        end

      end


      def self.prepare_rg_note(contact_map, hr_note)
        # if the note was already mapped to Ringio, we must update it there
        if (nm = NoteMap.find_by_hr_note_id(hr_note.id))
          rg_note = nm.rg_resource_note
        else
        # if the note is new, we must create it in Ringio
          rg_note = RingioAPI::Note.new
        end
        rg_note
      end


      def self.hr_note_to_rg_note(user_map, contact_map, hr_note, rg_note)
        rg_note.author_id = user_map.rg_user_id
        rg_note.contact_id = contact_map.rg_contact_id
        rg_note.body =  hr_note.body  
      end


      def self.apply_changes_rg_to_hr(contact_map, rg_updated_notes, rg_deleted_notes_ids)

        rg_updated_notes.each do |rg_note|
          # if the note was already mapped to Highrise, update it there
          if (nm = NoteMap.find_by_rg_note_id(rg_note.id))
            hr_note = nm.hr_resource_note
            self.rg_note_to_hr_note(contact_map,rg_note,hr_note)
          else
          # if the note is new, create it in Highrise and map it
            hr_note = Highrise::Note.new
            self.rg_note_to_hr_note(contact_map,rg_note,hr_note)
          end
          
          # if the Highrise note is saved properly and it didn't exist before, create a new note map
          new_hr_note = hr_note.new?
          unless new_hr_note
            hr_note = self.remove_subject_name(hr_note)
          end
          if hr_note.save! && new_hr_note
            new_nm = NoteMap.new(:contact_map_id => contact_map.id, :rg_note_id => rg_note.id, :hr_note_id => hr_note.id)
            new_nm.save!
          end
        end
        
        rg_deleted_notes_ids.each do |dn_id|
          # if the note was already mapped to Highrise, delete it there
          if (nm = NoteMap.find_by_rg_note_id(dn_id))
            hr_note = nm.hr_resource_note
            hr_note.destroy
            nm.destroy
          end
          # otherwise, don't do anything, because that Ringio contact has not been created yet in Highrise
        end
      end


      def self.remove_subject_name(hr_note)
        # TODO: remove this method or find a better way to do it (answer pending in the 37signals mailing list) 
        Highrise::Note.new(
          :author_id => hr_note.author_id,
          :body => hr_note.body,
          :collection_id => hr_note.collection_id,
          :collection_type => hr_note.collection_type,
          :created_at => hr_note.created_at,
          :group_id => hr_note.group_id,
          :id => hr_note.id,
          :owner_id => hr_note.owner_id,
          :subject_id => hr_note.subject_id,
          :subject_type => hr_note.subject_type,
          :updated_at => hr_note.updated_at,
          :visible_to => hr_note.visible_to
        )
      end


      def self.rg_note_to_hr_note(contact_map, rg_note,hr_note)
        # Highrise assumes that the author of the note is the currently authenticated user, we don't have to specify author_id
        hr_note.subject_id = contact_map.hr_party_id
        hr_note.subject_type = 'Party'
        # it is not necessary to specify if it is a Person or a Company (they can't have id collision),
        # and Highrise does not offer a way to specify it 
        hr_note.body = rg_note.body
      end

  end

end