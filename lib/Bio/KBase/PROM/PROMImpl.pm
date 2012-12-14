package Bio::KBase::PROM::PROMImpl;
use strict;
use Bio::KBase::Exceptions;
# Use Semantic Versioning (2.0.0-rc.1)
# http://semver.org 
our $VERSION = "0.1.0";

=head1 NAME

PROM

=head1 DESCRIPTION

PROM (Probabilistic Regulation of Metabolism) Service

This service enables the creation of FBA model objects which include constraints based on regulatory
networks and expression data, as described in [1].  Constraints are constructed by either automatically
aggregating necessary information from the CDS (if available for a given genome), or by adding user
expression and regulatory data.  PROM provides the capability to simulate transcription factor knockout
phenotypes.  PROM model objects are created in a user's workspace, and can be operated on and simulated
with the KBase FBA Modeling Service.

[1] Chandrasekarana S. and Price ND. Probabilistic integrative modeling of genome-scale metabolic and
regulatory networks in Escherichia coli and Mycobacterium tuberculosis. PNAS (2010) 107:17845-50.

created 11/27/2012 - msneddon

=cut

#BEGIN_HEADER
use Bio::KBase::ERDB_Service::Client;
use Bio::KBase::Regulation::Client;
use Bio::KBase::workspaceService::Client;
use Data::Dumper;
use Config::Simple;
use Data::UUID;
use JSON;
#END_HEADER

sub new
{
    my($class, @args) = @_;
    my $self = {
    };
    bless $self, $class;
    #BEGIN_CONSTRUCTOR
    
    
    #load a configuration file to determine where all the services live
    my $c = Config::Simple->new();
    $c->read("prom_config.ini");
    
    my $erdb_url = $c->param("service-urls.erdb");
    if($erdb_url) {
	$self->{'erdb'} = Bio::KBase::ERDB_Service::Client->new($erdb_url);
	print "Connecting ERDB Service client  to server: $erdb_url\n";
    } else {
	die "ERROR STARTING SERVICE! prom_config.ini file does not exist, or does not contain 'service-urls.erdb' variable.\n";
    }
    my $reg_url = $c->param("service-urls.regulation");
    if($reg_url) {
	$self->{'regulation'} = Bio::KBase::Regulation::Client->new($reg_url);
	#$self->{'regulation'} = Bio::KBase::ERDB_Service::Client->new("http://localhost:7061");
	print "Connecting Regulation Service client  to server: $reg_url\n";
    } else {
	die "ERROR STARTING SERVICE! prom_config.ini file does not exist, or does not contain 'service-urls.reglation' variable.\n";
	
    }
    my $workspace_url = $c->param("service-urls.workspace");
    if($workspace_url) {
	# may have to reconnect at each function call!
	$self->{'workspace'} = Bio::KBase::workspaceService::Client->new($workspace_url);
	print "Connecting Workspace Service client to server : $workspace_url\n";
    } else {
	die "ERROR STARTING SERVICE! prom_config.ini file does not exist, or does not contain 'service-urls.workspace' variable.\n";
    }
    
    my $scratch_space = $c->param("local-paths.scratch-space");
    if($scratch_space) {
	$self->{'scratch_space'} = $scratch_space;
	print "Scratch space for temporary files is set to : $scratch_space\n";
    } else {
	die "ERROR STARTING SERVICE! prom_confg.ini file does not exist, or does not contain 'local-paths.scratch-space' variable.\n";
    }
    
    $self->{'uuid_generator'} = new Data::UUID;
    
    #END_CONSTRUCTOR

    if ($self->can('_init_instance'))
    {
	$self->_init_instance();
    }
    return $self;
}

=head1 METHODS



=head2 create_from_genome

  $return_1, $return_2 = $obj->create_from_genome($genome)

=over 4

=item Parameter and return types

=begin html

<pre>
$genome is a genome_id
$return_1 is a status
$return_2 is a fbamodel_id
genome_id is a kbase_id
kbase_id is a string
status is a string
fbamodel_id is a string

</pre>

=end html

=begin text

$genome is a genome_id
$return_1 is a status
$return_2 is a fbamodel_id
genome_id is a kbase_id
kbase_id is a string
status is a string
fbamodel_id is a string


=end text



=item Description

DEPRICATED ALREADY!:
This method automatically constructs, if possible, an FBA model in the authenticated user's workspace that
includes PROM constraints.  Regulatory interactions are retrieved from the regulation service, and exression
data is compiled directly from the CDM.  A preconstructed FBA model cooresponding to the genome is also
retrieved from the CDM if the other data exists.  This method returns a status message that begins with either
'success' or 'failure', followed by potentially a long set of log or error messages.  If the method was
successful, then a valid fbamodel_id is returned and which can be used to reference the new model object.

=back

=cut

sub create_from_genome
{
    my $self = shift;
    my($genome) = @_;

    my @_bad_arguments;
    (!ref($genome)) or push(@_bad_arguments, "Invalid type for argument \"genome\" (value was \"$genome\")");
    if (@_bad_arguments) {
	my $msg = "Invalid arguments passed to create_from_genome:\n" . join("", map { "\t$_\n" } @_bad_arguments);
	Bio::KBase::Exceptions::ArgumentValidationError->throw(error => $msg,
							       method_name => 'create_from_genome');
    }

    my $ctx = $Bio::KBase::PROM::Service::CallContext;
    my($return_1, $return_2);
    #BEGIN create_from_genome
    my $erdb = $self->{'erdb'};
    my $status = "";
    $return_2 = ""; my $fbamodel_id="";
    
    # 1) GRAB REGULATORY NETWORK DATA
    $status .= "  -> querying the KBase Regulation Service for a regulatory network for genome: ".$genome."\n";
    
    
    
    # 2) GRAB EXPRESSION DATA FROM THE CDM (currently has on/off calls! but this will likely change...)
    # 
    $status .= "  -> searching the KBase Central Data Store for expression data for genome: ".$genome."\n";
    my $objectNames = 'HadResultsProducedBy ProbeSet HasResultsIn';
    my $filterClause = 'HadResultsProducedBy(from-link)=?';
    my $parameters = [$genome];
    my $fields = 'HasResultsIn(to-link)';
    my $count = 0; #as per ERDB doc, setting to zero returns all results
    my @experiment_list = @{$erdb->GetAll($objectNames, $filterClause, $parameters, $fields, $count)};
    
    if(scalar @experiment_list >0) {
	$status = $status."  -> found ".scalar(@experiment_list)." experiments for this genome.\n";
	
	# get the actual on/off calls (note, there is too much data to do this all at once)
	$objectNames = 'IndicatesSignalFor';
	$parameters = [];
	my $exp_counter = 0;
	foreach my $exp (@experiment_list) {
	    $exp_counter ++; if ($exp_counter>5) { last; }
	    print "  retrieving expermiment: ".${$exp}[0]."\n";
	    $filterClause = "IndicatesSignalFor(from-link)=?";
	    $fields = 'IndicatesSignalFor(from-link) IndicatesSignalFor(to-link) IndicatesSignalFor(level)';
	    my @expression_data = @{$erdb->GetAll($objectNames, $filterClause, [${$exp}[0]], $fields, $count)};
	    if(scalar @expression_data >0) {
		$status = $status."  -> found experiment '${$exp}[0]' with ".scalar(@expression_data)." gene on/off calls.\n";
		
		
		
		#if first 
		
	    } else {
		$status .= "warning - no gene expression data found for experiment '${$exp}[0]'.\n";
	    }
	}
	
    
    } else {
	$status = "failure - no gene expression experiments found for the specified genome.\n".$status;
    }

    
    
    
    
    
    # 3) USE MODEL SEED TO CREATE AN FBA MODEL OBJECT
    
    
    
    # 4) EXPORT THE MODEL TO THE WORKSPACE
    
    
    
    
    #print Dumper(@experiment_list)."\n";
    
    $return_1 = $status;
    $return_2 = $fbamodel_id;
    
    #END create_from_genome
    my @_bad_returns;
    (!ref($return_1)) or push(@_bad_returns, "Invalid type for return variable \"return_1\" (value was \"$return_1\")");
    (!ref($return_2)) or push(@_bad_returns, "Invalid type for return variable \"return_2\" (value was \"$return_2\")");
    if (@_bad_returns) {
	my $msg = "Invalid returns passed to create_from_genome:\n" . join("", map { "\t$_\n" } @_bad_returns);
	Bio::KBase::Exceptions::ArgumentValidationError->throw(error => $msg,
							       method_name => 'create_from_genome');
    }
    return($return_1, $return_2);
}




=head2 retrieve_expression_data

  $return_1, $return_2 = $obj->retrieve_expression_data($id, $workspace_name, $token)

=over 4

=item Parameter and return types

=begin html

<pre>
$id is a genome_id
$workspace_name is a workspace_name
$token is an auth_token
$return_1 is a status
$return_2 is an expression_data_collection_id
genome_id is a kbase_id
kbase_id is a string
workspace_name is a string
auth_token is a string
status is a string
expression_data_collection_id is a string

</pre>

=end html

=begin text

$id is a genome_id
$workspace_name is a workspace_name
$token is an auth_token
$return_1 is a status
$return_2 is an expression_data_collection_id
genome_id is a kbase_id
kbase_id is a string
workspace_name is a string
auth_token is a string
status is a string
expression_data_collection_id is a string


=end text



=item Description

This method takes a given genome id, and retrieves experimental expression data (if any) for the genome from
the CDM.  It then uses this expression data to construct an expression_data_collection in the current workspace.
Note that this method may take a long time to complete if there is a lot of CDM data for this genome.  Also note
that the current implementation relies on on/off calls being stored in the CDM (correct as of 12/2012).  This will
almost certainly change, but that means that the on/off calling algorithm must be added to this method, or
better yet implemented in the expression data service.

=back

=cut

sub retrieve_expression_data
{
    my $self = shift;
    my($id, $workspace_name, $token) = @_;

    my @_bad_arguments;
    (!ref($id)) or push(@_bad_arguments, "Invalid type for argument \"id\" (value was \"$id\")");
    (!ref($workspace_name)) or push(@_bad_arguments, "Invalid type for argument \"workspace_name\" (value was \"$workspace_name\")");
    (!ref($token)) or push(@_bad_arguments, "Invalid type for argument \"token\" (value was \"$token\")");
    if (@_bad_arguments) {
	my $msg = "Invalid arguments passed to retrieve_expression_data:\n" . join("", map { "\t$_\n" } @_bad_arguments);
	Bio::KBase::Exceptions::ArgumentValidationError->throw(error => $msg,
							       method_name => 'retrieve_expression_data');
    }

    my $ctx = $Bio::KBase::PROM::Service::CallContext;
    my($return_1, $return_2);
    #BEGIN retrieve_expression_data
    
    # setup the return variables
    my $status = ""; $return_1 = ""; 
    my $expression_data_collection_id=""; $return_2 = ""; 
    
    # make sure we are authentiated (for now auth token is passed directly)
    #if ($ctx->authenticated) {
        #$status .= "  -> user named ".$ctx->user_id." has been authenticated.\n";
	
	#check that the workspace is valid (note: can we get the token directly from ctx somehow?!?)
	my $ws = $self->{'workspace'};
	my $existing_workspaces = $ws->list_workspaces({auth=>$token});
	print "\n--".Dumper($existing_workspaces)."--\n";
	
	# grab the erdb service
	my $erdb = $self->{'erdb'};

	# GRAB EXPRESSION DATA FROM THE CDM (currently has on/off calls! but this will likely change...)
	$status .= "  -> searching the KBase Central Data Store for expression data for genome: ".$id."\n";
	my $objectNames = 'HadResultsProducedBy ProbeSet HasResultsIn';
	my $filterClause = 'HadResultsProducedBy(from-link)=?';
	my $parameters = [$id];
	my $fields = 'HasResultsIn(to-link)';
	my $count = 0; #as per ERDB doc, setting to zero returns all results
	my @experiment_list = @{$erdb->GetAll($objectNames, $filterClause, $parameters, $fields, $count)};
	
	my @expression_data_uuid_list = ();
	
	if(scalar @experiment_list >0) {
	    $status = $status."  -> found ".scalar(@experiment_list)." experiments for this genome.\n";
	    
	    # get the actual on/off calls (note, there is too much data to do this all at once)
	    $objectNames = 'IndicatesSignalFor';
	    $parameters = [];
	    
	    # append each experiment to the end of a temporary file
	    #$File::Temp::KEEP_ALL = 1; # FOR DEBUGGING ONLY, WE DON't WANT TO KEEP ALL FILES IN PRODUCTION
	    #my $tmp_file = File::Temp->new( TEMPLATE => 'promXXXXXX',
	    #		    DIR => $self->{'scratch_space'},
	    #		    SUFFIX => '.tmp');
	    my $exp_counter = 0;
	    foreach my $exp (@experiment_list) {
		$exp_counter ++; if ($exp_counter>5) { last; }
		print Dumper(${$exp}[0])."\n";
		$filterClause = "IndicatesSignalFor(from-link)=?";
		$fields = 'IndicatesSignalFor(from-link) IndicatesSignalFor(to-link) IndicatesSignalFor(level)';
		my @expression_data = @{$erdb->GetAll($objectNames, $filterClause, [${$exp}[0]], $fields, $count)};
		if(scalar @expression_data >0) {
		    $status = $status."  -> found experiment '${$exp}[0]' with ".scalar(@expression_data)." gene on/off calls.\n";
		    
		    # drop top level list and save as a data structure
		    my %on_off_calls;
		    foreach my $data (@expression_data) {
			$on_off_calls{${$data}[1]} = ${$data}[2]; 
		    }
		
		    # create a data structure to store the experimental data
		    my $data_uuid = $self->{'uuid_generator'}->create_str();
		    push @expression_data_uuid_list, $data_uuid;
		    print "uuid = ".$data_uuid."\n";
		    my $exp_data = {
			id => $data_uuid,
			on_off_call => \%on_off_calls,
			expression_data_source => 'KBase',
			expression_data_source_id => ${$exp}[0],
		    };
		    
		    # convert it to JSON
		    my $encoded_json_exp_data = encode_json $exp_data;
		    
		    # save this experiment to the workspace
		    my $workspace_save_obj_params = {
			id => $data_uuid,
			type => "Unspecified",
			data => $encoded_json_exp_data,
			workspace => $workspace_name,
			command => "PROM::retrieve_expression_data",
			auth => $token,
			json => 1,
			compressed => 0,
			retrieveFromURL => 0,
		    };
		    my $object_metadata = $ws->save_object($workspace_save_obj_params);
		    print Dumper($object_metadata)."\n";
		    
		    $status = $status."  -> saving data for experiment '${$exp}[0]' to your workspace with ID:$data_uuid\n";
		    
		    #print "DATA:\n".$encoded_json_data."\n";
		    
		    # dump the data to a file, making sure to sort the ids so features are in the correct order
		    #if($exp_counter==1) {
		    #   print $tmp_file "Experiment";
		    #   foreach my $fid (sort keys %on_off_calls) {
		    #       print $tmp_file "\t".$fid;
		    #}
		    #}
		    #print $tmp_file "\n";
		    #print $tmp_file ${$exp}[0]; #dump experiment name
		    #foreach my $fid (sort keys %on_off_calls) {
		    #	print $tmp_file "\t".$on_off_calls{$fid};
		    #}
		    #print $tmp_file "\n";
		} else {
		    $status .= "  -> warning - no gene expression data found for experiment '${$exp}[0]'.\n";
		}
	    }
	    
	    #################### TODO #######################
	    # now we save the collection to the workspace
	    
	    print Dumper(@expression_data_uuid_list)."\n";
	    
	    # create UUID for the collection
	    my $expression_data_collection_id = $self->{'uuid_generator'}->create_str();
	    print "collection uuid = ".$expression_data_collection_id."\n";
	    
	    # create the collection and encode it as JSON
	    my $exp_data_collection = {
		id => $expression_data_collection_id,
		expression_data => \@expression_data_uuid_list,
	    };
	    my $encoded_json_data_collection = encode_json $exp_data_collection;
	    print "DATA:\n".$encoded_json_data_collection."\n";
	    
	    # save the collection to the workspace
	    my $workspace_save_obj_params = {
		id => $expression_data_collection_id,
		type => "Unspecified",
		data => $encoded_json_data_collection,
		workspace => $workspace_name,
		command => "PROM::retrieve_expression_data",
		auth => $token,
		json => 1,
		compressed => 0,
		retrieveFromURL => 0,
	    };
	    my $object_metadata = $ws->save_object($workspace_save_obj_params);
	    print Dumper($object_metadata)."\n";
	    
	    $status = $status."  -> saving data for the collection of experiments with ID:$expression_data_collection_id\n";
	    $status = "SUCCESS.\n".$status."SUCCESS\n";
	    
	    
	} else {
	    $status = "failure - no gene expression experiments found for the specified genome.\n".$status;
	}
    
    
    
    
    #}
    #else {
    # 	$status = "failure - user and password combination could not be authenticated.\n".$status;
    #}
    
    
    # save the results
    $return_1 = $status;
    $return_2 = $expression_data_collection_id;
    
    #END retrieve_expression_data
    my @_bad_returns;
    (!ref($return_1)) or push(@_bad_returns, "Invalid type for return variable \"return_1\" (value was \"$return_1\")");
    (!ref($return_2)) or push(@_bad_returns, "Invalid type for return variable \"return_2\" (value was \"$return_2\")");
    if (@_bad_returns) {
	my $msg = "Invalid returns passed to retrieve_expression_data:\n" . join("", map { "\t$_\n" } @_bad_returns);
	Bio::KBase::Exceptions::ArgumentValidationError->throw(error => $msg,
							       method_name => 'retrieve_expression_data');
    }
    return($return_1, $return_2);
}




=head2 load_expression_data

  $return_1, $return_2 = $obj->load_expression_data($data)

=over 4

=item Parameter and return types

=begin html

<pre>
$data is a boolean_gene_expression_data_collection
$return_1 is a status
$return_2 is an expression_data_collection_id
boolean_gene_expression_data_collection is a reference to a hash where the following keys are defined:
	id has a value which is an expression_data_collection_id
	expression_data_ids has a value which is a reference to a list where each element is a boolean_gene_expression_data_id
expression_data_collection_id is a string
boolean_gene_expression_data_id is a string
status is a string

</pre>

=end html

=begin text

$data is a boolean_gene_expression_data_collection
$return_1 is a status
$return_2 is an expression_data_collection_id
boolean_gene_expression_data_collection is a reference to a hash where the following keys are defined:
	id has a value which is an expression_data_collection_id
	expression_data_ids has a value which is a reference to a list where each element is a boolean_gene_expression_data_id
expression_data_collection_id is a string
boolean_gene_expression_data_id is a string
status is a string


=end text



=item Description

This method allows the end user to upload gene expression data directly to a workspace.  This is useful if, for
instance, the gene expression data needed is private or not yet uploaded to the CDM.  Note that it is critical that
the gene ids are the same as the ids used in the FBA model!

=back

=cut

sub load_expression_data
{
    my $self = shift;
    my($data) = @_;

    my @_bad_arguments;
    (ref($data) eq 'HASH') or push(@_bad_arguments, "Invalid type for argument \"data\" (value was \"$data\")");
    if (@_bad_arguments) {
	my $msg = "Invalid arguments passed to load_expression_data:\n" . join("", map { "\t$_\n" } @_bad_arguments);
	Bio::KBase::Exceptions::ArgumentValidationError->throw(error => $msg,
							       method_name => 'load_expression_data');
    }

    my $ctx = $Bio::KBase::PROM::Service::CallContext;
    my($return_1, $return_2);
    #BEGIN load_expression_data
    #END load_expression_data
    my @_bad_returns;
    (!ref($return_1)) or push(@_bad_returns, "Invalid type for return variable \"return_1\" (value was \"$return_1\")");
    (!ref($return_2)) or push(@_bad_returns, "Invalid type for return variable \"return_2\" (value was \"$return_2\")");
    if (@_bad_returns) {
	my $msg = "Invalid returns passed to load_expression_data:\n" . join("", map { "\t$_\n" } @_bad_returns);
	Bio::KBase::Exceptions::ArgumentValidationError->throw(error => $msg,
							       method_name => 'load_expression_data');
    }
    return($return_1, $return_2);
}




=head2 retrieve_regulatory_network_data

  $return_1, $return_2 = $obj->retrieve_regulatory_network_data($id)

=over 4

=item Parameter and return types

=begin html

<pre>
$id is a regulomeModelId
$return_1 is a status
$return_2 is a regulatory_network_id
regulomeModelId is a string
status is a string
regulatory_network_id is a string

</pre>

=end html

=begin text

$id is a regulomeModelId
$return_1 is a status
$return_2 is a regulatory_network_id
regulomeModelId is a string
status is a string
regulatory_network_id is a string


=end text



=item Description

This method retrieves regulatory network data from the KBase Regulation service based on the Regulome model ID.  This
model must be defined for the same exact genome with which you are constructing the FBA model.  If a model does not exist for
your genome, the you have to build it yourself using the Regulation service.  See the Regulation service for more information on
how to retrieve a list of models for your genome, and how to propagate existing models to build a new model for your genome.

=back

=cut

sub retrieve_regulatory_network_data
{
    my $self = shift;
    my($id) = @_;

    my @_bad_arguments;
    (!ref($id)) or push(@_bad_arguments, "Invalid type for argument \"id\" (value was \"$id\")");
    if (@_bad_arguments) {
	my $msg = "Invalid arguments passed to retrieve_regulatory_network_data:\n" . join("", map { "\t$_\n" } @_bad_arguments);
	Bio::KBase::Exceptions::ArgumentValidationError->throw(error => $msg,
							       method_name => 'retrieve_regulatory_network_data');
    }

    my $ctx = $Bio::KBase::PROM::Service::CallContext;
    my($return_1, $return_2);
    #BEGIN retrieve_regulatory_network_data
    #END retrieve_regulatory_network_data
    my @_bad_returns;
    (!ref($return_1)) or push(@_bad_returns, "Invalid type for return variable \"return_1\" (value was \"$return_1\")");
    (!ref($return_2)) or push(@_bad_returns, "Invalid type for return variable \"return_2\" (value was \"$return_2\")");
    if (@_bad_returns) {
	my $msg = "Invalid returns passed to retrieve_regulatory_network_data:\n" . join("", map { "\t$_\n" } @_bad_returns);
	Bio::KBase::Exceptions::ArgumentValidationError->throw(error => $msg,
							       method_name => 'retrieve_regulatory_network_data');
    }
    return($return_1, $return_2);
}




=head2 load_regulatory_network_data

  $return_1, $return_2 = $obj->load_regulatory_network_data($id)

=over 4

=item Parameter and return types

=begin html

<pre>
$id is a regulomeModelId
$return_1 is a status
$return_2 is a regulatory_network_id
regulomeModelId is a string
status is a string
regulatory_network_id is a string

</pre>

=end html

=begin text

$id is a regulomeModelId
$return_1 is a status
$return_2 is a regulatory_network_id
regulomeModelId is a string
status is a string
regulatory_network_id is a string


=end text



=item Description

Given your own regulatory network for a given genome, load it into the workspace so that it can be used to construct a PROM
model. Make sure your IDs for each gene are consistant with your FBA model and your gene expression data!

=back

=cut

sub load_regulatory_network_data
{
    my $self = shift;
    my($id) = @_;

    my @_bad_arguments;
    (!ref($id)) or push(@_bad_arguments, "Invalid type for argument \"id\" (value was \"$id\")");
    if (@_bad_arguments) {
	my $msg = "Invalid arguments passed to load_regulatory_network_data:\n" . join("", map { "\t$_\n" } @_bad_arguments);
	Bio::KBase::Exceptions::ArgumentValidationError->throw(error => $msg,
							       method_name => 'load_regulatory_network_data');
    }

    my $ctx = $Bio::KBase::PROM::Service::CallContext;
    my($return_1, $return_2);
    #BEGIN load_regulatory_network_data
    #END load_regulatory_network_data
    my @_bad_returns;
    (!ref($return_1)) or push(@_bad_returns, "Invalid type for return variable \"return_1\" (value was \"$return_1\")");
    (!ref($return_2)) or push(@_bad_returns, "Invalid type for return variable \"return_2\" (value was \"$return_2\")");
    if (@_bad_returns) {
	my $msg = "Invalid returns passed to load_regulatory_network_data:\n" . join("", map { "\t$_\n" } @_bad_returns);
	Bio::KBase::Exceptions::ArgumentValidationError->throw(error => $msg,
							       method_name => 'load_regulatory_network_data');
    }
    return($return_1, $return_2);
}




=head2 create_prom_model

  $return_1, $return_2 = $obj->create_prom_model($e_id, $r_id, $fba_id)

=over 4

=item Parameter and return types

=begin html

<pre>
$e_id is an expression_data_collection_id
$r_id is a regulatory_network_id
$fba_id is a fbamodel_id
$return_1 is a status
$return_2 is a prom_model_id
expression_data_collection_id is a string
regulatory_network_id is a string
fbamodel_id is a string
status is a string
prom_model_id is a string

</pre>

=end html

=begin text

$e_id is an expression_data_collection_id
$r_id is a regulatory_network_id
$fba_id is a fbamodel_id
$return_1 is a status
$return_2 is a prom_model_id
expression_data_collection_id is a string
regulatory_network_id is a string
fbamodel_id is a string
status is a string
prom_model_id is a string


=end text



=item Description

Once you have loaded gene expression data and a regulatory network and have created an fba model for your genome, then
you can use this method to create add PROM contraints to the FBA model, thus creating a PROM model.  This method will then return
you the ID of the PROM model object created in your workspace.  The PROM Model object can then be simulated, visualized, edited, etc.
using methods from the FBAModeling Service.

=back

=cut

sub create_prom_model
{
    my $self = shift;
    my($e_id, $r_id, $fba_id) = @_;

    my @_bad_arguments;
    (!ref($e_id)) or push(@_bad_arguments, "Invalid type for argument \"e_id\" (value was \"$e_id\")");
    (!ref($r_id)) or push(@_bad_arguments, "Invalid type for argument \"r_id\" (value was \"$r_id\")");
    (!ref($fba_id)) or push(@_bad_arguments, "Invalid type for argument \"fba_id\" (value was \"$fba_id\")");
    if (@_bad_arguments) {
	my $msg = "Invalid arguments passed to create_prom_model:\n" . join("", map { "\t$_\n" } @_bad_arguments);
	Bio::KBase::Exceptions::ArgumentValidationError->throw(error => $msg,
							       method_name => 'create_prom_model');
    }

    my $ctx = $Bio::KBase::PROM::Service::CallContext;
    my($return_1, $return_2);
    #BEGIN create_prom_model
    #END create_prom_model
    my @_bad_returns;
    (!ref($return_1)) or push(@_bad_returns, "Invalid type for return variable \"return_1\" (value was \"$return_1\")");
    (!ref($return_2)) or push(@_bad_returns, "Invalid type for return variable \"return_2\" (value was \"$return_2\")");
    if (@_bad_returns) {
	my $msg = "Invalid returns passed to create_prom_model:\n" . join("", map { "\t$_\n" } @_bad_returns);
	Bio::KBase::Exceptions::ArgumentValidationError->throw(error => $msg,
							       method_name => 'create_prom_model');
    }
    return($return_1, $return_2);
}




=head2 version 

  $return = $obj->version()

=over 4

=item Parameter and return types

=begin html

<pre>
$return is a string
</pre>

=end html

=begin text

$return is a string

=end text

=item Description

Return the module version. This is a Semantic Versioning number.

=back

=cut

sub version {
    return $VERSION;
}

=head1 TYPES



=head2 kbase_id

=over 4



=item Description

A KBase ID is a string starting with the characters "kb|".  KBase IDs are typed. The types are
designated using a short string.  KBase IDs may be hierarchical.  See the standard KBase documentation
for more information.


=item Definition

=begin html

<pre>
a string
</pre>

=end html

=begin text

a string

=end text

=back



=head2 feature_id

=over 4



=item Description

A KBase ID for a genome feature


=item Definition

=begin html

<pre>
a kbase_id
</pre>

=end html

=begin text

a kbase_id

=end text

=back



=head2 genome_id

=over 4



=item Description

A KBase ID for a genome


=item Definition

=begin html

<pre>
a kbase_id
</pre>

=end html

=begin text

a kbase_id

=end text

=back



=head2 workspace_name

=over 4



=item Description

The name of a workspace


=item Definition

=begin html

<pre>
a string
</pre>

=end html

=begin text

a string

=end text

=back



=head2 fbamodel_id

=over 4



=item Description

A workspace ID for an fba model


=item Definition

=begin html

<pre>
a string
</pre>

=end html

=begin text

a string

=end text

=back



=head2 boolean_gene_expression_data_id

=over 4



=item Description

A workspace ID for a gene expression data object.


=item Definition

=begin html

<pre>
a string
</pre>

=end html

=begin text

a string

=end text

=back



=head2 expression_data_collection_id

=over 4



=item Description

A workspace id for a set of expression data on/off calls needed by PROM


=item Definition

=begin html

<pre>
a string
</pre>

=end html

=begin text

a string

=end text

=back



=head2 regulatory_network_id

=over 4



=item Description

A workspace ID for a regulatory network object, needed by PROM


=item Definition

=begin html

<pre>
a string
</pre>

=end html

=begin text

a string

=end text

=back



=head2 regulomeModelId

=over 4



=item Description

The ID of a regulome model as registered with the Regulation service


=item Definition

=begin html

<pre>
a string
</pre>

=end html

=begin text

a string

=end text

=back



=head2 status

=over 4



=item Description

Status message used by this service to provide information on the final status of a step


=item Definition

=begin html

<pre>
a string
</pre>

=end html

=begin text

a string

=end text

=back



=head2 prom_model_id

=over 4



=item Description

A workspace ID for the prom model object, used to access any models created by this service in
a user's workpace


=item Definition

=begin html

<pre>
a string
</pre>

=end html

=begin text

a string

=end text

=back



=head2 source

=over 4



=item Description

Specifies the source of a data object, e.g. KBase or MicrobesOnline


=item Definition

=begin html

<pre>
a string
</pre>

=end html

=begin text

a string

=end text

=back



=head2 source_id

=over 4



=item Description

Specifies the ID of the data object in the source


=item Definition

=begin html

<pre>
a string
</pre>

=end html

=begin text

a string

=end text

=back



=head2 auth_token

=over 4



=item Description

The string representation of the bearer token needed to authenticate on the workspace service


=item Definition

=begin html

<pre>
a string
</pre>

=end html

=begin text

a string

=end text

=back



=head2 on_off_state

=over 4



=item Description

Indicates on/off state of a gene, 1=on, -1=off, 0=unknown


=item Definition

=begin html

<pre>
an int
</pre>

=end html

=begin text

an int

=end text

=back



=head2 boolean_gene_expression_data

=over 4



=item Description

A simplified representation of gene expression data under a SINGLE condition. Note that the condition
information is not explicitly tracked here. also NOTE: this data object should be migrated to the Expression
Data service, and simply imported here.

    mapping<feature_id,on_off_state> on_off_call - a mapping of genome features to on/off calls under the given
                                           condition (true=on, false=off).  It is therefore assumed that
                                           the features are protein coding genes.
    source expression_data_source        - the source of this collection of expression data
    source_id expression_data_source_id  - the id of the data ob


=item Definition

=begin html

<pre>
a reference to a hash where the following keys are defined:
id has a value which is a boolean_gene_expression_data_id
on_off_call has a value which is a reference to a hash where the key is a feature_id and the value is an on_off_state
expression_data_source has a value which is a source
expression_data_source_id has a value which is a source

</pre>

=end html

=begin text

a reference to a hash where the following keys are defined:
id has a value which is a boolean_gene_expression_data_id
on_off_call has a value which is a reference to a hash where the key is a feature_id and the value is an on_off_state
expression_data_source has a value which is a source
expression_data_source_id has a value which is a source


=end text

=back



=head2 boolean_gene_expression_data_collection

=over 4



=item Description

A collection of gene expression data for a single genome under a range of conditions.  This data is returned
as a list of IDs for boolean gene expression data objects in the workspace.  This is a simple object for creating
a PROM Model. NOTE: this data object should be migrated to the Expression Data service, and simply imported here.


=item Definition

=begin html

<pre>
a reference to a hash where the following keys are defined:
id has a value which is an expression_data_collection_id
expression_data_ids has a value which is a reference to a list where each element is a boolean_gene_expression_data_id

</pre>

=end html

=begin text

a reference to a hash where the following keys are defined:
id has a value which is an expression_data_collection_id
expression_data_ids has a value which is a reference to a list where each element is a boolean_gene_expression_data_id


=end text

=back



=head2 regulatory_interaction

=over 4



=item Description

A simplified representation of a regulatory interaction that also stores the probability of the interaction
(specificially, as the probability the target is on given that the regulator is off), which is necessary for PROM
to construct FBA constraints.  NOTE: this data object should be migrated to the Regulation service, and simply
imported here. NOTE 2: feature_id may have to be changed to be a more general ID, as models could potentially be
loaded that are not in the kbase namespace. Note then that in this case everything, including expression data
and the fba model must be in the same namespace. NOTE: this data object should be migrated to the Regulation
service, and simply imported here.

    feature_id transcriptionFactor  - the genome feature that is the regulator
    feature_id transcriptionTarget  - the genome feature that is the target of regulation
    float probabilityTTonGivenTFoff - the probability that the transcriptional target is ON, given that the
                                      transcription factor is not expressed, as defined in Candrasekarana &
                                      Price, PNAS 2010 and used to predict cumulative effects of multiple
                                      regulatory interactions with a single target.
    float probabilityTTonGivenTFon - the probability that the transcriptional target is ON, given that the
                                      transcription factor is expressed


=item Definition

=begin html

<pre>
a reference to a hash where the following keys are defined:
transcriptionFactor has a value which is a feature_id
transcriptionTarget has a value which is a feature_id
probabilityTTonGivenTFoff has a value which is a float
probabilityTTonGivenTFon has a value which is a float

</pre>

=end html

=begin text

a reference to a hash where the following keys are defined:
transcriptionFactor has a value which is a feature_id
transcriptionTarget has a value which is a feature_id
probabilityTTonGivenTFoff has a value which is a float
probabilityTTonGivenTFon has a value which is a float


=end text

=back



=head2 regulatory_network

=over 4



=item Description

A collection of regulatory interactions that together form a regulatory network. This is an extremely
simplified data object for use in constructing a PROM model.  NOTE: this data object should be migrated to
the Regulation service, and simply imported here.


=item Definition

=begin html

<pre>
a reference to a list where each element is a regulatory_interaction
</pre>

=end html

=begin text

a reference to a list where each element is a regulatory_interaction

=end text

=back



=head2 prom_constraint

=over 4



=item Description

An object that encapsulates the information necessary to apply PROM-based constraints to an FBA model. This
includes a regulatory network consisting of a set of regulatory interactions, and a copy of the expression data
that is required to compute the probability of regulatory interactions.  A prom constraint object can then be
associated with an FBA model to create a PROM model that can be simulated with tools from the FBAModelingService.

    list<regulatory_interaction> regulatory_network           - a collection of regulatory interactions that
                                                                compose a regulatory network.  Probabilty values
                                                                are initially set to nan until they are computed
                                                                from the set of expression experiments.
    list<boolean_gene_expression_data> expression_experiments - a collection of expression data experiments that
                                                                coorespond to this genome of interest.


=item Definition

=begin html

<pre>
a reference to a hash where the following keys are defined:
regulatory_network has a value which is a regulatory_network
expression_data_collection_id has a value which is an expression_data_collection_id

</pre>

=end html

=begin text

a reference to a hash where the following keys are defined:
regulatory_network has a value which is a regulatory_network
expression_data_collection_id has a value which is an expression_data_collection_id


=end text

=back



=cut

1;
