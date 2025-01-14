require 'spec_helper'
require_relative 'service_operation_shared'

module VCAP::CloudController
  RSpec.describe ManagedServiceInstance, type: :model do
    let(:service_instance) { VCAP::CloudController::ManagedServiceInstance.make }
    let(:email) { Sham.email }
    let(:guid) { Sham.guid }

    after { VCAP::Request.current_id = nil }

    before do
      allow(VCAP::CloudController::SecurityContext).to receive(:current_user_email) { email }

      client = instance_double(VCAP::Services::ServiceBrokers::V2::Client, unbind: nil, deprovision: nil)
      allow_any_instance_of(Service).to receive(:client).and_return(client)
    end

    it { is_expected.to have_timestamp_columns }

    describe 'Associations' do
      it { is_expected.to have_associated :service_plan }
      it { is_expected.to have_associated :space }
      it do
        is_expected.to have_associated :service_bindings, associated_instance: ->(service_instance) {
          app = VCAP::CloudController::AppModel.make(space: service_instance.space)
          ServiceBinding.make(app: app, service_instance: service_instance, credentials: Sham.service_credentials)
        }
      end
    end

    describe 'Validations' do
      it { is_expected.to validate_presence :name }
      it { is_expected.to validate_presence :service_plan }
      it { is_expected.to validate_presence :space }
      it { is_expected.to validate_uniqueness :space_id, :name, { error_key: :name } }
      it { is_expected.to strip_whitespace :name }
      let(:max_tags) { ['a' * 1024, 'b' * 1024] }

      it 'accepts user-provided tags where combined length of all tags is exactly 2048 characters' do
        expect {
          ManagedServiceInstance.make tags: max_tags
        }.not_to raise_error
      end

      it 'accepts user-provided tags where combined length of all tags is less than 2048 characters' do
        expect {
          ManagedServiceInstance.make tags: max_tags[0..50]
        }.not_to raise_error
      end

      it 'does not accept user-provided tags with combined length of over 2048 characters' do
        expect {
          ManagedServiceInstance.make tags: max_tags + ['z']
        }.to raise_error(Sequel::ValidationFailed).with_message('tags too_long')
      end

      it 'does not accept a single user-provided tag of length greater than 2048 characters' do
        expect {
          ManagedServiceInstance.make tags: ['a' * 2049]
        }.to raise_error(Sequel::ValidationFailed).with_message('tags too_long')
      end

      it 'should not bind an app and a service instance from different app spaces' do
        ProcessModelFactory.make(space: service_instance.space)
        service_binding = ServiceBinding.make
        expect {
          service_instance.add_service_binding(service_binding)
        }.to raise_error ServiceInstance::InvalidServiceBinding
      end

      it 'validates org and space quotas using MaxServiceInstancePolicy' do
        space_quota_definition = SpaceQuotaDefinition.make
        service_instance.space.space_quota_definition = space_quota_definition
        max_memory_policies = service_instance.validation_policies.select { |policy| policy.instance_of? MaxServiceInstancePolicy }
        expect(max_memory_policies.length).to eq(2)
        targets = max_memory_policies.collect(&:quota_definition)
        expect(targets).to match_array([space_quota_definition, service_instance.organization.quota_definition])
      end

      it 'validates org and space quotas using PaidServiceInstancePolicy' do
        space_quota_definition = SpaceQuotaDefinition.make
        service_instance.space.space_quota_definition = space_quota_definition
        policies = service_instance.validation_policies.select { |policy| policy.instance_of? PaidServiceInstancePolicy }
        expect(policies.length).to eq(2)
        targets = policies.collect(&:quota_definition)
        expect(targets).to match_array([space_quota_definition, service_instance.organization.quota_definition])
      end
    end

    describe '#valid_with_plan?' do
      let(:original_plan) { ServicePlan.make(free: true) }

      let(:free_quota) do
        QuotaDefinition.make(
          total_services: 1,
          non_basic_services_allowed: false
        )
      end
      let(:org) { Organization.make(quota_definition: free_quota) }
      let(:space) { Space.make(organization: org) }
      let(:service_instance) { ManagedServiceInstance.make(
        space: space,
        service_plan: original_plan
      )
      }

      context 'for valid requested plans' do
        let(:new_plan) { ServicePlan.make(free: true) }

        it 'does not change the plan' do
          service_instance.valid_with_plan?(new_plan)
          expect(service_instance.service_plan).to eq(original_plan)
        end

        it 'returns true' do
          expect(service_instance.valid_with_plan?(new_plan)).to eq(true)
        end
      end

      context 'for invalid requested plans' do
        let(:new_plan) { ServicePlan.make(free: false) }

        it 'does not change the plan' do
          service_instance.valid_with_plan?(new_plan)
          expect(service_instance.service_plan).to eq(original_plan)
        end

        it 'returns false' do
          expect(service_instance.valid_with_plan?(new_plan)).to eq(false)
        end
      end
    end

    describe 'Serialization' do
      it { is_expected.to export_attributes :name, :credentials, :service_plan_guid, :space_guid, :gateway_data, :dashboard_url, :type, :last_operation, :tags, :maintenance_info }
      it { is_expected.to import_attributes :name, :service_plan_guid, :space_guid, :gateway_data, :maintenance_info }
    end

    describe '#create' do
      it 'has a guid when constructed' do
        instance = ManagedServiceInstance.new
        expect(instance.guid).to be
      end

      it 'saves with is_gateway_service true' do
        instance = ManagedServiceInstance.make
        expect(instance.refresh.is_gateway_service).to eq(true)
      end

      it 'creates a CREATED service usage event' do
        instance = ManagedServiceInstance.make

        event = ServiceUsageEvent.last
        expect(ServiceUsageEvent.count).to eq(1)
        expect(event.state).to eq(Repositories::ServiceUsageEventRepository::CREATED_EVENT_STATE)
        expect(event).to match_service_instance(instance)
      end

      it 'allows really long dashboard urls' do
        instance = ManagedServiceInstance.make
        instance.update dashboard_url: 'a' * 1024
        expect(instance.guid).to be
      end
    end

    describe '#save_with_new_operation' do
      let(:service_instance) { ManagedServiceInstance.make }
      let(:developer) { make_developer_for_space(service_instance.space) }

      before do
        allow(VCAP::CloudController::SecurityContext).to receive(:current_user).and_return(developer)
      end

      it 'creates a new last_operation object and associates it with the service instance' do
        instance = { dashboard_url: 'a-different-url.com' }
        last_operation = {
          state: 'in progress',
          description: '10%'
        }
        service_instance.save_with_new_operation(instance, last_operation)

        service_instance.reload
        expect(service_instance.dashboard_url).to eq 'a-different-url.com'
        expect(service_instance.last_operation.state).to eq 'in progress'
        expect(service_instance.last_operation.description).to eq '10%'
      end

      context 'when the instance already has a last operation' do
        before do
          last_operation = { state: 'finished' }
          service_instance.save_with_new_operation({}, last_operation)
          service_instance.reload
          @old_guid = service_instance.last_operation.guid
        end

        it 'creates a new operation' do
          last_operation = { state: 'in progress' }
          service_instance.save_with_new_operation({}, last_operation)

          service_instance.reload
          expect(service_instance.last_operation.guid).not_to eq(@old_guid)
        end
      end
    end

    describe '#save_and_update_operation' do
      let(:service_instance) { ManagedServiceInstance.make }
      let(:developer) { make_developer_for_space(service_instance.space) }
      let(:manager) { make_manager_for_space(service_instance.space) }
      let(:admin_read_only) { set_current_user_as_admin_read_only(user: User.make) }

      before do
        last_operation = { state: 'in progress', description: '10%' }
        service_instance.save_with_new_operation({}, last_operation)
        service_instance.reload
        @old_guid = service_instance.last_operation.guid
      end

      it 'updates the existing last_operation object' do
        attrs = {
          last_operation: {
            state: 'in progress',
            description: '20%'
          },
          dashboard_url: 'a-different-url.com'
        }
        service_instance.save_and_update_operation(attrs)

        service_instance.reload
        expect(service_instance.dashboard_url).to eq 'a-different-url.com'
        expect(service_instance.last_operation.state).to eq 'in progress'
        expect(service_instance.last_operation.guid).to eq @old_guid
        expect(service_instance.last_operation.description).to eq '20%'
      end
    end

    describe '#route_service?' do
      context 'when the service instance is not a route service' do
        let!(:service_instance) { ManagedServiceInstance.make }
        it 'returns false' do
          expect(service_instance.route_service?).to be_falsey
        end
      end

      context 'when the service instance is a route service' do
        let!(:service_instance) { ManagedServiceInstance.make(:routing) }
        it 'returns false' do
          expect(service_instance.route_service?).to be_truthy
        end
      end
    end

    describe '#shareable?' do
      let(:service) { Service.make }
      let(:service_instance) { ManagedServiceInstance.make }

      before do
        allow(service).to receive(:shareable?).and_return(is_shareable)
        allow(service_instance).to receive(:service).and_return(service)
      end

      context 'when the service instance is not a shareable' do
        let(:is_shareable) { false }

        it 'returns false' do
          expect(service_instance).to_not be_shareable
        end
      end

      context 'when the service instance is shareable' do
        let(:is_shareable) { true }

        it 'returns true' do
          expect(service_instance).to be_shareable
        end
      end
    end

    describe '#as_summary_json' do
      let(:service_broker) { ServiceBroker.make(name: 'some_broker') }
      let(:service) { Service.make(label: 'YourSQL', guid: '9876XZ', service_broker: service_broker) }
      let(:maintenance_info) { nil }
      let(:service_plan) { ServicePlan.make(name: 'Gold Plan', guid: '12763abc', service: service, maintenance_info: maintenance_info) }
      let(:service_instance_maintenance_info) { nil }
      let(:developer) { make_developer_for_space(service_instance.space) }
      let(:manager) { make_manager_for_space(service_instance.space) }

      subject(:service_instance) { ManagedServiceInstance.make(service_plan: service_plan, maintenance_info: service_instance_maintenance_info) }

      it 'returns detailed summary' do
        last_operation = ServiceInstanceOperation.make(
          state: 'in progress',
          description: '50% all the time',
          type: 'create',
        )
        service_instance.service_instance_operation = last_operation

        service_instance.dashboard_url = 'http://dashboard.example.com'

        expect(service_instance.as_summary_json).to include({
          'guid' => subject.guid,
          'name' => subject.name,
          'bound_app_count' => 0,
          'dashboard_url' => 'http://dashboard.example.com',
          'service_broker_name' => service_broker.name,
          'maintenance_info' => {},
          'service_plan' => {
            'guid' => '12763abc',
            'name' => 'Gold Plan',
            'maintenance_info' => {},
            'service' => {
              'guid' => '9876XZ',
              'label' => 'YourSQL',
              'provider' => nil,
              'version' => nil,
            }
          }
        })

        expect(service_instance.as_summary_json['last_operation']).to include(
          {
            'state' => 'in progress',
            'description' => '50% all the time',
            'type' => 'create',
          }
        )
      end

      context 'when maintenence info is present' do
        let(:maintenance_info) { { version: '2.0.0' } }
        let(:service_instance_maintenance_info) { { version: '1.0.0' } }

        it 'returns the maintenanca_info on service instance and plan' do
          service_instance_summary = service_instance.as_summary_json
          expect(service_instance_summary['maintenance_info']).to eq({ 'version' => '1.0.0' })
          expect(service_instance_summary['service_plan']['maintenance_info']).to eq({ 'version' => '2.0.0' })
        end
      end

      context 'when the last_operation does not exist' do
        it 'sets the field to nil' do
          expect(service_instance.as_summary_json['last_operation']).to be_nil
        end
      end
    end

    context 'quota' do
      let(:free_plan) { ServicePlan.make(free: true) }
      let(:paid_plan) { ServicePlan.make(free: false) }

      let(:free_quota) do
        QuotaDefinition.make(
          total_services: 1,
          non_basic_services_allowed: false
        )
      end
      let(:paid_quota) do
        QuotaDefinition.make(
          total_services: 1,
          non_basic_services_allowed: true
        )
      end

      context 'exceed quota' do
        it 'should raise quota error when quota is exceeded' do
          org = Organization.make(quota_definition: free_quota)
          space = Space.make(organization: org)
          ManagedServiceInstance.make(
            space: space,
            service_plan: free_plan
          ).save(validate: false)
          space.refresh
          expect do
            ManagedServiceInstance.make(
              space: space,
              service_plan: free_plan
            )
          end.to raise_error(Sequel::ValidationFailed, /quota service_instance_quota_exceeded/)
        end

        it 'should not raise error when quota is not exceeded' do
          org = Organization.make(quota_definition: paid_quota)
          space = Space.make(organization: org)
          expect do
            ManagedServiceInstance.make(
              space: space,
              service_plan: free_plan
            )
          end.to_not raise_error
        end
      end

      context 'create free services' do
        it 'should not raise error when created in free quota' do
          org = Organization.make(quota_definition: free_quota)
          space = Space.make(organization: org)
          expect do
            ManagedServiceInstance.make(
              space: space,
              service_plan: free_plan
            )
          end.to_not raise_error
        end

        it 'should not raise error when created in paid quota' do
          org = Organization.make(quota_definition: paid_quota)
          space = Space.make(organization: org)
          expect do
            ManagedServiceInstance.make(
              space: space,
              service_plan: free_plan
            )
          end.to_not raise_error
        end
      end

      context 'create paid services' do
        it 'should raise error when created in free quota' do
          org = Organization.make(quota_definition: free_quota)
          space = Space.make(organization: org)
          expect do
            ManagedServiceInstance.make(
              space: space,
              service_plan: paid_plan
            )
          end.to raise_error(Sequel::ValidationFailed,
                             /service_plan paid_services_not_allowed_by_quota/)
        end

        it 'should not raise error when created in paid quota' do
          org = Organization.make(quota_definition: paid_quota)
          space = Space.make(organization: org)
          expect do
            ManagedServiceInstance.make(
              space: space,
              service_plan: paid_plan
            )
          end.to_not raise_error
        end
      end
    end

    describe '#destroy' do
      context 'when the instance has bindings' do
        before do
          ServiceBinding.make(
            app: AppModel.make(space: service_instance.space),
            service_instance: service_instance
          )
        end

        it 'raises a ForeignKeyConstraintViolation error' do
          expect { service_instance.destroy }.to raise_error(Sequel::ForeignKeyConstraintViolation)
        end
      end

      it 'creates a DELETED service usage event' do
        service_instance.destroy

        event = VCAP::CloudController::ServiceUsageEvent.last

        expect(VCAP::CloudController::ServiceUsageEvent.count).to eq(2)
        expect(event.state).to eq(Repositories::ServiceUsageEventRepository::DELETED_EVENT_STATE)
        expect(event).to match_service_instance(service_instance)
      end

      it 'cascade deletes all ServiceInstanceOperations for this instance' do
        last_operation = ServiceInstanceOperation.make
        service_instance.service_instance_operation = last_operation

        service_instance.destroy

        expect(ServiceInstance.find(guid: service_instance.guid)).to be_nil
        expect(ServiceInstanceOperation.find(guid: last_operation.guid)).to be_nil
      end
    end

    describe '#bindable?' do
      let(:service_instance) { ManagedServiceInstance.make }

      context 'when the service plan is bindable' do
        before { expect(service_instance.service_plan).to receive(:bindable?).and_return(true) }

        specify { expect(service_instance).to be_bindable }
      end

      context 'when the service plan is not bindable' do
        before { expect(service_instance.service_plan).to receive(:bindable?).and_return(false) }

        specify { expect(service_instance).not_to be_bindable }
      end
    end

    describe 'tags' do
      let(:instance_tags) { %w(a b c) }
      let(:service_tags) { %w(relational mysql) }
      let(:service_instance) { ManagedServiceInstance.make(service_plan: service_plan, tags: instance_tags) }
      let(:service_plan) { ServicePlan.make(service: service) }
      let(:service) { Service.make(tags: service_tags) }

      describe '#tags' do
        it 'returns the instance tags' do
          expect(service_instance.tags).to eq instance_tags
        end

        context 'when there are no tags' do
          let(:instance_tags) { nil }
          it 'returns an empty array' do
            expect(service_instance.tags).to eq []
          end
        end
      end

      describe '#merged_tags' do
        it 'returns the service tags merged with the instance tags' do
          expect(service_instance.merged_tags).to eq(service_tags + instance_tags)
        end

        context 'when the instance tags are not set' do
          let(:service_instance) { ManagedServiceInstance.make service_plan: service_plan }

          it 'returns only the service tags' do
            expect(service_instance.merged_tags).to eq(service_tags)
          end
        end

        context 'when the service tags are not set' do
          let(:service_plan) { ServicePlan.make }

          it 'returns only the instance tags' do
            expect(service_instance.merged_tags).to eq(instance_tags)
          end
        end

        context 'when no service or instance tags are set' do
          let(:instance_tags) { nil }
          let(:service_tags) { nil }

          it 'returns an empty array' do
            expect(service_instance.merged_tags).to eq([])
          end
        end

        context 'when there are duplicate service tags' do
          let(:service_tags) { %w(relational mysql mysql) }

          it 'does not display duplicate tags' do
            expect(service_instance.merged_tags).to match_array(%w(a b c relational mysql))
          end
        end

        context 'when there are duplicate instance tags' do
          let(:instance_tags) { %w(a a b c) }

          it 'does not display duplicate tags' do
            expect(service_instance.merged_tags).to match_array(%w(a b c relational mysql))
          end
        end

        context 'when there are instance tags which are duplicates of a service tag' do
          let(:instance_tags) { %w(mysql a b c) }

          it 'does not display duplicate tags' do
            expect(service_instance.merged_tags).to match_array(%w(a b c relational mysql))
          end
        end
      end
    end

    it_behaves_like 'a model including the ServiceOperationMixin', ManagedServiceInstance, :service_instance_operation, ServiceInstanceOperation, :service_instance_id

    describe '#to_hash' do
      let(:opts)            { { attrs: [:credentials] } }

      it 'includes the last operation hash' do
        updated_at_time = Time.now.utc
        last_operation = ServiceInstanceOperation.make(
          state: 'in progress',
          description: '50% all the time',
          type: 'create',
          updated_at: updated_at_time
        )

        service_instance.service_instance_operation = last_operation
        expect(service_instance.to_hash['last_operation']).to include({
          'state' => 'in progress',
          'description' => '50% all the time',
          'type' => 'create',
        })

        expect(service_instance.to_hash['last_operation']['updated_at']).to be
      end
    end

    describe 'maintenance_info' do
      let(:expected_value) { { version: '1.0' }.stringify_keys }
      let(:maintenance_info) { { maintenance_info: expected_value } }

      it 'should serialize and deserialize it as a JSON' do
        service_instance.update_service_instance(maintenance_info)
        service_instance.reload
        expect(service_instance.maintenance_info).to eq(expected_value)
      end
    end
  end
end
