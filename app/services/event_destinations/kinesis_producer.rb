# frozen_string_literal: true

module EventDestinations
  # Thin wrapper over the Kinesis SDK. In log mode the client is stubbed, so the SDK still
  # validates the request parameters but nothing leaves the process: going live is a
  # constructor change, not a redesign.
  class KinesisProducer
    def initialize(stream:)
      @stream = stream
    end

    def produce(data:, partition_key:)
      payload = JSON.generate(data)

      response = client.put_record(
        stream_arn: stream.stream_arn,
        data: payload,
        partition_key:
      )

      if stream.log_only?
        Rails.logger.info(
          "[event_destinations] put_record stream=#{stream.stream_arn} " \
          "partition_key=#{partition_key} bytes=#{payload.bytesize} data=#{payload}"
        )
      end

      response
    end

    private

    attr_reader :stream

    def client
      @client ||= Aws::Kinesis::Client.new(
        region: stream.region,
        stub_responses: stream.log_only?
      )
    end
  end
end
