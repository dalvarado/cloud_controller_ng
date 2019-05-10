require 'messages/base_message'

module VCAP::CloudController
  class RouteCreateMessage < BaseMessage
    MAXIMUM_DOMAIN_LABEL_LENGTH = 63

    register_allowed_keys [
      :host,
      :relationships
    ]

    validates :host,
      allow_nil: true,
      string: true,
      length: {
        maximum: MAXIMUM_DOMAIN_LABEL_LENGTH
      },
      format: {
        with: /\A([\w\-]+|\*)?\z/,
        message: 'must be either "*" or contain only alphanumeric characters, "_", or "-"',
      }

    validates :relationships, presence: true

    validates_with NoAdditionalKeysValidator
    validates_with RelationshipValidator

    delegate :space_guid, to: :relationships_message
    delegate :domain_guid, to: :relationships_message

    def relationships_message
      # need the & instaed of doing if requested(rel..) because we can't delegate if rl_msg nil
      @relationships_message ||= Relationships.new(relationships&.deep_symbolize_keys)
    end

    class Relationships < BaseMessage
      register_allowed_keys [:space, :domain]

      validates_with NoAdditionalKeysValidator
      validates :space, presence: true, to_one_relationship: true
      validates :domain, presence: true, to_one_relationship: true

      def space_guid
        HashUtils.dig(space, :data, :guid)
      end

      def domain_guid
        HashUtils.dig(domain, :data, :guid)
      end
    end
  end
end