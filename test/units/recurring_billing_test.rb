require File.dirname(__FILE__) + '/../test_helper'

class RecurringBillingTest < Test::Unit::TestCase
  fixtures :users, :freemium_subscriptions, :freemium_subscription_plans, :freemium_credit_cards

  class FreemiumSubscription < ::FreemiumSubscription
    include Freemium::RecurringBilling
  end

  def setup
    Freemium.gateway = Freemium::Gateways::Test.new
  end

  def test_run_billing
    FreemiumSubscription.expects(:process_new_transactions).once
    FreemiumSubscription.expects(:find_expirable).once.returns([])
    FreemiumSubscription.expects(:expire).once
    FreemiumSubscription.run_billing
  end

  def test_run_billing_sends_report
    FreemiumSubscription.stubs(:process_new_transactions)
    Freemium.stubs(:admin_report_recipients).returns("test@example.com")

    Freemium.mailer.expects(:deliver_admin_report)
    FreemiumSubscription.run_billing
  end

  def test_subscriptions_to_expire
    # making a one-off fixture set, basically
    create_billable_subscription # this subscription qualifies
    create_billable_subscription(:subscription_plan => freemium_subscription_plans(:free)) # this subscription would qualify, except it's for the free plan
    create_billable_subscription(:paid_through => Date.today) # this subscription would qualify, except it's already paid
    create_billable_subscription(:coupon => FreemiumCoupon.create!(:description => "Complimentary", :discount_percentage => 100)) # should NOT be billable because it's free
    s = create_billable_subscription # this subscription would qualify, except it's already been set to expire
    s.update_attribute :expire_on, Date.today + 1

    expirable = FreemiumSubscription.send(:find_expirable)
    assert expirable.all? {|subscription| subscription.paid?}, "free subscriptions don't expire"
    assert expirable.all? {|subscription| subscription.paid_through < Date.today}, "paid subscriptions don't expire"
    assert expirable.all? {|subscription| !subscription.expire_on or subscription.expire_on < subscription.paid_through}, "subscriptions already expiring aren't included"
    assert_equal 1, expirable.size    
  end

  def test_processing_new_transactions
    subscription = freemium_subscriptions(:bobs_subscription)
    paid_through = subscription.paid_through
    t = Freemium::Transaction.new(:billing_key => subscription.billing_key, :amount => subscription.subscription_plan.rate, :success => true)
    FreemiumSubscription.stubs(:new_transactions).returns([t])

    # the actual test
    FreemiumSubscription.send :process_new_transactions
    assert_equal (paid_through + 1.month).to_s, subscription.reload.paid_through.to_s, "extended by two months"
  end
  
  def test_processing_new_transactions_multiple_months
    subscription = freemium_subscriptions(:bobs_subscription)
    paid_through = subscription.paid_through = Date.parse("2009-01-31 00:00:00")
    t = Freemium::Transaction.new(:billing_key => subscription.billing_key, :amount => subscription.subscription_plan.rate, :success => true)
    FreemiumSubscription.stubs(:new_transactions).returns([t,t])

    # the actual test
    FreemiumSubscription.send :process_new_transactions
    assert_equal (paid_through + 2.months).to_s, subscription.reload.paid_through.to_s, "extended by two months"
  end  

  def test_processing_a_failed_transaction
    subscription = freemium_subscriptions(:bobs_subscription)
    paid_through = subscription.paid_through
    t = Freemium::Transaction.new(:billing_key => subscription.billing_key, :amount => subscription.subscription_plan.rate, :success => false)
    FreemiumSubscription.stubs(:new_transactions).returns([t])

    # the actual test
    assert_nil subscription.expire_on
    FreemiumSubscription.send :process_new_transactions
    assert_equal paid_through, subscription.reload.paid_through, "not extended"
    assert_not_nil subscription.expire_on
  end

  def test_all_new_transactions
    last_transaction_at = FreemiumSubscription.maximum(:last_transaction_at)
    method_args = FreemiumSubscription.send(:new_transactions)
    assert_equal last_transaction_at, method_args[:after]
  end

  protected

  def create_billable_subscription(options = {})
    FreemiumSubscription.create!({
      :subscription_plan => freemium_subscription_plans(:premium),
      :subscribable => User.new(:name => 'a'),
      :paid_through => Date.today - 1,
      :credit_card => FreemiumCreditCard.sample
    }.merge(options))
  end
end