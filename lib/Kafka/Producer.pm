package Kafka::Producer;

=head1 NAME

Kafka::Producer - Perl interface for Kafka producer client.

=head1 VERSION

This documentation refers to C<Kafka::Producer> version 1.001013 .

=cut

#-- Pragmas --------------------------------------------------------------------

use 5.010;
use strict;
use warnings;

# ENVIRONMENT ------------------------------------------------------------------

our $VERSION = '1.001013';

#-- load the modules -----------------------------------------------------------

use Carp;
use Params::Util qw(
    _ARRAY0
    _INSTANCE
    _NONNEGINT
    _NUMBER
    _STRING
);
use Scalar::Util qw(
    blessed
);
use Scalar::Util::Numeric qw(
    isint
);
use Time::HiRes qw(time);

use Kafka qw(
    %ERROR
    $COMPRESSION_GZIP
    $COMPRESSION_NONE
    $COMPRESSION_SNAPPY
    $ERROR_CANNOT_GET_METADATA
    $ERROR_MISMATCH_ARGUMENT
    $REQUEST_TIMEOUT
    $NOT_SEND_ANY_RESPONSE
    $WAIT_WRITTEN_TO_LOCAL_LOG
    $BLOCK_UNTIL_IS_COMMITTED
);
use Kafka::Connection;
use Kafka::Exceptions;
use Kafka::Internals qw(
    $APIKEY_PRODUCE
    $MAX_CORRELATIONID
    $MAX_INT16
    $MAX_INT32
    $PRODUCER_ANY_OFFSET
    _get_CorrelationId
    format_message
);

#-- declarations ---------------------------------------------------------------

=head1 SYNOPSIS

    use 5.010;
    use strict;
    use warnings;

    use Scalar::Util qw(
        blessed
    );
    use Try::Tiny;

    use Kafka::Connection;
    use Kafka::Producer;

    my ( $connection, $producer );
    try {

        #-- Connection
        $connection = Kafka::Connection->new( host => 'localhost' );

        #-- Producer
        $producer = Kafka::Producer->new( Connection => $connection );

        # Sending a single message
        my $response = $producer->send(
            'mytopic',          # topic
            0,                  # partition
            'Single message'    # message
        );

        # Sending a series of messages
        $response = $producer->send(
            'mytopic',          # topic
            0,                  # partition
            [                   # messages
                'The first message',
                'The second message',
                'The third message',
            ]
        );

    } catch {
        my $error = $_;
        if ( blessed( $error ) && $error->isa( 'Kafka::Exception' ) ) {
            warn 'Error: (', $error->code, ') ',  $error->message, "\n";
            exit;
        } else {
            die $error;
        }
    };

    # Closes the producer and cleans up
    undef $producer;
    $connection->close;
    undef $connection;

=head1 DESCRIPTION

Kafka producer API is implemented by C<Kafka::Producer> class.

The main features of the C<Kafka::Producer> class are:

=over 3

=item *

Provides object-oriented API for producing messages.

=item *

Provides Kafka PRODUCE requests.

=back

=cut

my %known_compression_codecs = map { $_ => 1 } (
    $COMPRESSION_NONE,
    $COMPRESSION_GZIP,
    $COMPRESSION_SNAPPY,
);

#-- constructor ----------------------------------------------------------------

=head2 CONSTRUCTOR

=head3 C<new>

Creates new producer client object.

C<new()> takes arguments in key-value pairs. The following arguments are currently recognized:

=over 3

=item C<Connection =E<gt> $connection>

C<$connection> is the L<Kafka::Connection|Kafka::Connection> object responsible for communication with
the Apache Kafka cluster.

=item C<ClientId =E<gt> $client_id>

This is a user supplied identifier (string) for the client application.

If C<ClientId> is not passed to constructor, its value will be automatically assigned
(to string C<'producer'>).

=item C<RequiredAcks =E<gt> $acks>

The C<$acks> should be an int16 signed integer.

Indicates how many acknowledgements the servers should receive before responding to the request.

If it is C<$NOT_SEND_ANY_RESPONSE> the server does not send any response.

If it is C<$WAIT_WRITTEN_TO_LOCAL_LOG>, (default)
the server will wait until the data is written to the local log before sending a response.

If it is C<$BLOCK_UNTIL_IS_COMMITTED>
the server will block until the message is committed by all in sync replicas before sending a response.

C<$NOT_SEND_ANY_RESPONSE>, C<$WAIT_WRITTEN_TO_LOCAL_LOG>, C<$BLOCK_UNTIL_IS_COMMITTED>
can be imported from the L<Kafka|Kafka> module.

=item C<Timeout =E<gt> $timeout>

This provides a maximum time the server can await the receipt
of the number of acknowledgements in C<RequiredAcks>.

The C<$timeout> in seconds, could be any integer or floating-point type not bigger than int32 positive integer.

Optional, default = C<$REQUEST_TIMEOUT>.

C<$REQUEST_TIMEOUT> is the default timeout that can be imported from the
L<Kafka|Kafka> module.

=item C<UseTimestamps =E<gt> $timestamps>

If C<$timestamps> is true then messages that are send will always have timestamps with the current time unless
the Timestamp is provided in C<Kafka::Producer-<gt>send> request.

=back

=cut
sub new {
    my ( $class, @args ) = @_;

    my $self = bless {
        Connection      => undef,
        ClientId        => undef,
        RequiredAcks    => $WAIT_WRITTEN_TO_LOCAL_LOG,
        Timeout         => $REQUEST_TIMEOUT,
        UseTimestamps   => undef,
    }, $class;

    while ( @args ) {
        my $k = shift @args;
        $self->{ $k } = shift @args if exists $self->{ $k };
    }

    $self->{ClientId}       //= 'producer';

    $self->_error( $ERROR_MISMATCH_ARGUMENT, 'Connection' )
        unless _INSTANCE( $self->{Connection}, 'Kafka::Connection' );
    $self->_error( $ERROR_MISMATCH_ARGUMENT, 'ClientId' )
        unless ( $self->{ClientId} eq q{} || defined( _STRING( $self->{ClientId} ) ) ) && !utf8::is_utf8( $self->{ClientId} );
    $self->_error( $ERROR_MISMATCH_ARGUMENT, format_message( 'Timeout (%s)', $self->{Timeout} ) )
        unless defined _NUMBER( $self->{Timeout} ) && int( $self->{Timeout} * 1000 ) >= 1 && int( $self->{Timeout} * 1000 ) <= $MAX_INT32;

    my $required_acks = $self->{RequiredAcks};
    $self->_error( $ERROR_MISMATCH_ARGUMENT, 'RequiredAcks' )
        unless
               defined( $required_acks )
            && isint( $required_acks )
            && (
                   $required_acks == $NOT_SEND_ANY_RESPONSE
                || $required_acks == $WAIT_WRITTEN_TO_LOCAL_LOG
                || $required_acks == $BLOCK_UNTIL_IS_COMMITTED
            )
    ;

    return $self;
}

#-- public attributes ----------------------------------------------------------

=head2 METHODS

The following methods are defined for the C<Kafka::Producer> class:

=cut

#-- public methods -------------------------------------------------------------

=head3 C<send( $topic, $partition, $messages, $key, $compression_codec )>

Sends a messages on a L<Kafka::Connection|Kafka::Connection> object.

Returns a non-blank value (a reference to a hash with server response description)
if the message is successfully sent.

C<send()> takes the following arguments:

=over 3

=item C<$topic>

The C<$topic> must be a normal non-false string of non-zero length.

=item C<$partition>

The C<$partition> must be a non-negative integer.

=item C<$messages>

The C<$messages> is an arbitrary amount of data (a simple data string or
a reference to an array of the data strings).

=item C<$key>

The C<$key> is an optional message key, must be a string.
C<$key> may used in the producer for partitioning with each message,
so the consumer knows the partitioning key.

=item C<$compression_codec>

Optional.

C<$compression_codec> sets the required type of C<$messages> compression,
if the compression is desirable.

Supported codecs:
C<$COMPRESSION_NONE>,
C<$COMPRESSION_GZIP>,
C<$COMPRESSION_SNAPPY>.
The defaults that can be imported from the L<Kafka|Kafka> module.

Do not use C<$Kafka::SEND_MAX_ATTEMPTS> in C<Kafka::Producer-<gt>send> request to prevent duplicates.

=back

=cut
sub send {
    my ( $self, $topic, $partition, $messages, $key, $compression_codec, $timestamp ) = @_;

    $key //= q{};

    $self->_error( $ERROR_MISMATCH_ARGUMENT, 'topic' )
        unless defined( $topic ) && ( $topic eq q{} || defined( _STRING( $topic ) ) ) && !utf8::is_utf8( $topic );
    $self->_error( $ERROR_MISMATCH_ARGUMENT, 'partition' )
        unless defined( $partition ) && isint( $partition ) && $partition >= 0;
    $self->_error( $ERROR_MISMATCH_ARGUMENT, 'messages' )
        unless defined( _STRING( $messages ) ) || _ARRAY0( $messages );
    $self->_error( $ERROR_MISMATCH_ARGUMENT, 'key' )
        unless ( $key eq q{} || defined( _STRING( $key ) ) ) && !utf8::is_utf8( $key );
    $self->_error( $ERROR_MISMATCH_ARGUMENT, 'compression_codec' )
        unless ( !defined( $compression_codec ) || $known_compression_codecs{ $compression_codec } );

    $messages = [ $messages ] unless ref( $messages );
    foreach my $message ( @$messages ) {
        $self->_error( $ERROR_MISMATCH_ARGUMENT, format_message( 'message = %s', $message ) )
            unless defined( $message ) && ( $message eq q{} || ( defined( _STRING( $message ) ) && !utf8::is_utf8( $message ) ) );
    }

    my $MessageSet = [];
    my $request = {
        ApiKey                              => $APIKEY_PRODUCE,
        CorrelationId                       => _get_CorrelationId(),
        ClientId                            => $self->{ClientId},
        RequiredAcks                        => $self->{RequiredAcks},
        Timeout                             => int( $self->{Timeout} * 1000 ),
        topics                              => [
            {
                TopicName                   => $topic,
                partitions                  => [
                    {
                        Partition           => $partition,
                        MessageSet          => $MessageSet,
                    },
                ],
            },
        ],
    };

    if (!defined($timestamp) && $self->{UseTimestamps}) {
        $timestamp = int (time() * 1000);
    }

    foreach my $message ( @$messages ) {
        push @$MessageSet, {
            Offset  => $PRODUCER_ANY_OFFSET,
            Key     => $key,
            Value   => $message,
            Timestamp => $timestamp,
        };
    }

    my $result = $self->{Connection}->receive_response_to_request( $request, $compression_codec, $self->{Timeout} );
    return $result;
}

#-- private attributes ---------------------------------------------------------

#-- private methods ------------------------------------------------------------

# Handler for errors
sub _error {
    my $self = shift;

    Kafka::Exception::Producer->throw( throw_args( @_ ) );

    return;
}

#-- Closes and cleans up -------------------------------------------------------

1;

__END__

=head1 DIAGNOSTICS

When error is detected, an exception, represented by object of C<Kafka::Exception::Producer> class,
is thrown (see L<Kafka::Exceptions|Kafka::Exceptions>).

L<code|Kafka::Exceptions/code> and a more descriptive L<message|Kafka::Exceptions/message> provide
information about thrown exception. Consult documentation of the L<Kafka::Exceptions|Kafka::Exceptions>
for the list of all available methods.

Authors suggest using of L<Try::Tiny|Try::Tiny>'s C<try> and C<catch> to handle exceptions while
working with L<Kafka|Kafka> package.

=over 3

=item C<Invalid argument>

Invalid arguments were provided to a C<new>
L<constructor|/CONSTRUCTOR> or to other L<method|/METHODS>.

=item C<Cannot send>

Request cannot be sent.

=item C<Cannot receive>

Response cannot be received.

=item C<Cannot bind>

TCP connection cannot be established on a given host and port.

=item C<Cannot get metadata>

IO error is present, errors found in the structure of the reply or the reply contains a non-zero error codes.

=item C<Description leader not found>

Information about the server-leader is missing in metadata.

=item C<Mismatch CorrelationId>

C<CorrelationId> of response doesn't match one in request.

=item C<There are no known brokers>

Information about brokers in the cluster is missing.

=item C<Cannot get metadata>

Obtained metadata is incorrect or failed to obtain metadata.

=back

=head1 SEE ALSO

The basic operation of the Kafka package modules:

L<Kafka|Kafka> - constants and messages used by the Kafka package modules.

L<Kafka::Connection|Kafka::Connection> - interface to connect to a Kafka cluster.

L<Kafka::Producer|Kafka::Producer> - interface for producing client.

L<Kafka::Consumer|Kafka::Consumer> - interface for consuming client.

L<Kafka::Message|Kafka::Message> - interface to access Kafka message
properties.

L<Kafka::Int64|Kafka::Int64> - functions to work with 64 bit elements of the
protocol on 32 bit systems.

L<Kafka::Protocol|Kafka::Protocol> - functions to process messages in the
Apache Kafka's Protocol.

L<Kafka::IO|Kafka::IO> - low-level interface for communication with Kafka server.

L<Kafka::Exceptions|Kafka::Exceptions> - module designated to handle Kafka exceptions.

L<Kafka::Internals|Kafka::Internals> - internal constants and functions used
by several package modules.

A wealth of detail about the Apache Kafka and the Kafka Protocol:

Main page at L<http://kafka.apache.org/>

Kafka Protocol at L<https://cwiki.apache.org/confluence/display/KAFKA/A+Guide+To+The+Kafka+Protocol>

=head1 SOURCE CODE

Kafka package is hosted on GitHub:
L<https://github.com/TrackingSoft/Kafka>

=head1 AUTHOR

Sergey Gladkov, E<lt>sgladkov@trackingsoft.comE<gt>

Please use GitHub project link above to report problems or contact authors.

=head1 CONTRIBUTORS

Alexander Solovey

Jeremy Jordan

Sergiy Zuban

Vlad Marchenko

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2012-2016 by TrackingSoft LLC.

This package is free software; you can redistribute it and/or modify it under
the same terms as Perl itself. See I<perlartistic> at
L<http://dev.perl.org/licenses/artistic.html>.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE.

=cut
