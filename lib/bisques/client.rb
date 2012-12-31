require 'bisques/aws_connection'
require 'bisques/aws_credentials'
require 'bisques/queue'
require 'bisques/queue_listener'
require 'digest/md5'

module Bisques
  # Bisques is a client for Amazon SQS. All of the API calls made to SQS are
  # called via methods on this class.
  #
  # === Example
  #
  #   client = Bisques::Client.new('us-east-1', 'my_queues_', AwsCredentials.new(aws_key, aws_secret))
  #   client.list_queues
  #
  class Client
    # The queue prefix when interacting with SQS. The client will only be able
    # to see queues whose name has this prefix.
    attr_accessor :queue_prefix

    include AwsConnection

    # Initialize a client object. The AWS region must be specified. For
    # example, 'us-east-1'. An optional queue prefix can be provided to
    # restrict the queues this client can see and interact with. AWS
    # credentials must be provided, or defaults set in AwsCredentials.
    def initialize(region, queue_prefix = nil, credentials = AwsCredentials.default)
      super(region, "sqs", credentials)
      @queue_prefix = queue_prefix
    end

    # Returns a Queue object representing an SQS queue, creating it if it does
    # not already exist.
    def get_or_create_queue(name)
      get_queue(name) || create_queue(name, {})
    end

    # Creates a new SQS queue and returns a Queue object.
    def create_queue(name, attributes = {})
      response = action("CreateQueue", {"QueueName" => Queue.sanitize_name("#{queue_prefix}#{name}")}.merge(attributes))

      if response.success?
        Queue.new(self, response.doc.xpath("//QueueUrl").text)
      else
        raise "Could not create queue #{name}"
      end
    end

    # Deletes an SQS queue at a given path.
    def delete_queue(queue_url)
      response = action("DeleteQueue", queue_url)
    end

    # Get an SQS queue by name. Returns a Queue object if the queue is found, otherwise nil.
    def get_queue(name, options = {})
      response = action("GetQueueUrl", {"QueueName" => Queue.sanitize_name("#{queue_prefix}#{name}")}.merge(options))
      
      if response.success?
        Queue.new(self, response.doc.xpath("//QueueUrl").text)
      end

    rescue Bisques::AwsActionError => e
      raise unless e.code == "AWS.SimpleQueueService.NonExistentQueue"
    end

    # Return an array of Queue objects representing the queues found in SQS. An
    # optional prefix can be supplied to restrict the queues found. This prefix
    # is additional to the client prefix.
    #
    # Example:
    #
    #   # Delete all the queues
    #   client.list_queues.each do |queue|
    #     queue.delete
    #   end
    #
    def list_queues(prefix = "")
      response = action("ListQueues", "QueueNamePrefix" => "#{queue_prefix}#{prefix}")
      response.doc.xpath("//ListQueuesResult/QueueUrl").map(&:text).map do |url|
        Queue.new(self, url)
      end
    end

    # Get the attributes for a queue. Takes an array of attribute names.
    # Defaults to ["All"] which returns all the available attributes.
    #
    # This returns an AwsResponse object.
    def get_queue_attributes(queue_url, attributes = ["All"])
      attributes = attributes.map(&:to_s)

      query = Hash[*attributes.each_with_index.map do |attribute, index|
        ["AttributeName.#{index+1}", attribute]
      end.flatten]

      action("GetQueueAttributes", queue_url, query)
    end

    # Put a message on a queue. Takes the queue url and the message body, which
    # should be a string. An optional delay seconds argument can be added if
    # the message should not become visible immediately.
    #
    # Example:
    #
    #   client.send_message(queue.path, "test message")
    #
    def send_message(queue_url, message_body, delay_seconds=nil)
      options = {"MessageBody" => message_body}
      options["DelaySeconds"] = delay_seconds if delay_seconds

      tries = 0
      md5 = Digest::MD5.hexdigest(message_body)

      begin
        tries += 1
        response = action("SendMessage", queue_url, options)
        
        returned_md5 = response.doc.xpath("//MD5OfMessageBody").text
        raise MessageHasWrongMd5Error.new(message_body, md5, returned_md5) unless md5 == returned_md5
      rescue MessageHasWrongMd5Error
        if tries < 2
          retry
        else
          raise
        end
      end
    end

    # Delete a message from a queue. The message is deleted by the handle given
    # when the message is retrieved.
    def delete_message(queue_url, receipt_handle)
      response = action("DeleteMessage", queue_url, {"ReceiptHandle" => receipt_handle})
    end

    # Receive a message from a queue. Takes the queue url and an optional hash.
    def receive_message(queue_url, options = {})
      # validate_options(options, %w(AttributeName MaxNumberOfMessages VisibilityTimeout WaitTimeSeconds))
      action("ReceiveMessage", queue_url, options)
    end

    # Change the visibility of a message on the queue. This is useful if you
    # have retrieved a message and now want to keep it hidden for longer before
    # deleting it, or if you have a job and decide you cannot action it and
    # want to return it to the queue sooner.
    def change_message_visibility(queue_url, receipt_handle, visibility_timeout)
      action("ChangeMessageVisibility", queue_url, {"ReceiptHandle" => receipt_handle, "VisibilityTimeout" => visibility_timeout})
    end
  end
end